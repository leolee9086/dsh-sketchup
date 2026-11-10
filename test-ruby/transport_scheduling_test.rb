# frozen_string_literal: true
require_relative "test_helper"

# 用真实本机 TCP 套接字复现 SketchUp 原生操作占用解释器后，
# 网络线程恢复运行时墙钟预算已经过期、但内核中的连接仍然可用的情形。
module TransportSchedulingFixture
  def self.pair
    listener = TCPServer.new("127.0.0.1", 0)
    local = TCPSocket.new("127.0.0.1", listener.addr[1])
    remote = listener.accept
    yield local, remote
  ensure
    local.close if local && !local.closed?
    remote.close if remote && !remote.closed?
    listener.close if listener && !listener.closed?
  end

  def self.client(socket)
    result = DSHSketchupBridge::WebSocketClient.new(host: "127.0.0.1", port: 1, path: "/", timeout: 0.05, read_timeout: 0.05)
    result.instance_variable_set(:@socket, socket)
    result
  end

  def self.read_exact(socket, length)
    result = +"".b
    result << socket.readpartial(length - result.bytesize) while result.bytesize < length
    result
  end

  def self.client_json(socket)
    first, second = read_exact(socket, 2).bytes
    BridgeTests.equal(0x81, first)
    BridgeTests.assert((second & 0x80) != 0, "client frame must be masked")
    length = second & 0x7f
    length = read_exact(socket, 2).unpack1("n") if length == 126
    length = read_exact(socket, 8).unpack1("Q>") if length == 127
    mask = read_exact(socket, 4)
    payload = read_exact(socket, length)
    decoded = payload.bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*")
    JSON.parse(decoded)
  end
end

BridgeTests.test("ready heartbeat write survives scheduler delay beyond its deadline") do
  TransportSchedulingFixture.pair do |local, remote|
    client = TransportSchedulingFixture.client(local)
    # 第一次读时钟建立 deadline，第二次相当于线程失去调度两秒。
    now = 100.0
    client.define_singleton_method(:monotonic_time) { now += 2.0 }
    wire = client.send(:encode_frame, 1, '{"t":"pong"}')
    client.send(:write_all, local, wire)
    received = Timeout.timeout(1) { TransportSchedulingFixture.client_json(remote) }
    BridgeTests.equal({ "t" => "pong" }, received)
    client.close
  end
end

BridgeTests.test("already available frame survives an expired read deadline") do
  TransportSchedulingFixture.pair do |local, remote|
    client = TransportSchedulingFixture.client(local)
    text = '{"t":"ping"}'
    remote.write([0x81, text.bytesize].pack("CC") + text)
    client.instance_variable_set(:@read_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)
    BridgeTests.equal([true, 1, text], client.send(:read_frame))
    client.close
  end
end

BridgeTests.test("expired deadline still rejects an actually unreadable socket") do
  TransportSchedulingFixture.pair do |local, _remote|
    client = TransportSchedulingFixture.client(local)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    BridgeTests.raises(Timeout::Error, /read timed out/) { client.send(:wait_io, local, false, deadline) }
    client.close
  end
end

BridgeTests.test("initial hello reaches peer before the asynchronous writer is scheduled") do
  listener = TCPServer.new("127.0.0.1", 0)
  hello = { "t" => "hello", "caps" => { "instanceId" => "schedule-test" } }
  peer = Thread.new do
    socket = nil
    Timeout.timeout(3) do
      socket = listener.accept
      headers = +""
      headers << socket.readpartial(1) until headers.end_with?("\r\n\r\n")
      key = headers[/Sec-WebSocket-Key: ([^\r\n]+)/, 1]
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + DSHSketchupBridge::WebSocketClient::WEBSOCKET_GUID))
      socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
      TransportSchedulingFixture.client_json(socket)
    end
  ensure
    socket.close if socket && !socket.closed?
  end
  client = DSHSketchupBridge::WebSocketClient.new(host: "127.0.0.1", port: listener.addr[1], path: "/ext/sketchup")
  # 故意不启动写线程；握手不得依赖它获得下一次调度机会。
  client.define_singleton_method(:start_writer) { @fixture_writer_skipped = true }
  client.connect(initial_frame: hello)
  BridgeTests.assert(peer.join(1), "hello waited for the writer thread")
  BridgeTests.equal(hello, peer.value)
ensure
  client.close if client
  listener.close if listener && !listener.closed?
  peer.kill if peer && peer.alive?
  peer.join if peer
end
