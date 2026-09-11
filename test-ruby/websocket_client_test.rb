# frozen_string_literal: true
require_relative "test_helper"

module WebSocketFixture
  def self.header(opcode, length, fin = true)
    first = (fin ? 0x80 : 0) | opcode
    if length < 126
      [first, length].pack("CC")
    elsif length <= 0xFFFF
      [first, 126, length].pack("CCn")
    else
      [first, 127, length / 4_294_967_296, length % 4_294_967_296].pack("CCN2")
    end
  end
  def self.frame(opcode, data, fin = true)
    header(opcode, data.bytesize, fin) + data.b
  end
  def self.buffered(data)
    client = DSHSketchupBridge::WebSocketClient.new(host: "127.0.0.1", port: 1, path: "/")
    client.instance_variable_set(:@socket, StringIO.new)
    client.instance_variable_set(:@read_buffer, data.b)
    client
  end
  # Isolated ephemeral sockets only; these never contact the real DSH/SketchUp.
  def self.socket_pair
    listener = TCPServer.new("127.0.0.1", 0)
    local = TCPSocket.new("127.0.0.1", listener.addr[1])
    remote = listener.accept
    listener.close
    yield local, remote
  ensure
    local.close if local && !local.closed?
    remote.close if remote && !remote.closed?
    listener.close if listener && !listener.closed?
  end
  def self.attached(socket, timeout: 0.1, read_timeout: 0.1)
    client = DSHSketchupBridge::WebSocketClient.new(host: "127.0.0.1", port: 1, path: "/", timeout: timeout, read_timeout: read_timeout)
    client.instance_variable_set(:@socket, socket)
    client
  end
end

BridgeTests.test("real HTTP upgrade starts writer and preserves coalesced first message") do
  listener = TCPServer.new("127.0.0.1", 0)
  server_thread = Thread.new do
    socket = nil
    Timeout.timeout(3) do
      socket = listener.accept
      headers = +""
      headers << socket.readpartial(1024) until headers.include?("\r\n\r\n")
      key = headers[/Sec-WebSocket-Key: ([^\r\n]+)/, 1]
      BridgeTests.assert(headers.include?("Origin: sketchup://dsh-bridge"))
      accept = Base64.strict_encode64(Digest::SHA1.digest(key + DSHSketchupBridge::WebSocketClient::WEBSOCKET_GUID))
      response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      socket.write(response + WebSocketFixture.frame(1, '{"t":"hello.ok"}'))
      first, second = socket.read(2).bytes
      BridgeTests.equal(0x81, first)
      BridgeTests.assert((second & 0x80) != 0)
      mask = socket.read(4)
      payload = socket.read(second & 0x7f)
      decoded = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      JSON.parse(decoded)
    end
  ensure
    socket.close if socket && !socket.closed?
  end
  client = DSHSketchupBridge::WebSocketClient.new(host: "127.0.0.1", port: listener.addr[1], path: "/ext/sketchup")
  client.connect
  BridgeTests.equal({ "t" => "hello.ok" }, client.read_json)
  client.send_json({ "t" => "hello" })
  BridgeTests.assert(server_thread.join(4), "upgrade fixture timed out")
  BridgeTests.equal({ "t" => "hello" }, server_thread.value)
ensure
  client.close if client
  listener.close if listener && !listener.closed?
  server_thread.kill if server_thread && server_thread.alive?
end

BridgeTests.test("fragmented UTF-8 JSON accepts interleaved ping and clears state") do
  # Split inside the multibyte character: validate UTF-8 only after reassembly.
  text = JSON.generate({ "value" => "汉字" }).b
  split = text.index("汉".b) + 1
  client = WebSocketFixture.buffered(
    WebSocketFixture.frame(1, text.byteslice(0, split), false) +
    WebSocketFixture.frame(9, "ping") +
    WebSocketFixture.frame(0, text.byteslice(split..-1)))
  BridgeTests.equal({ "value" => "汉字" }, client.read_json)
  BridgeTests.equal(nil, client.instance_variable_get(:@fragment_opcode))
  BridgeTests.equal("", client.instance_variable_get(:@fragments))
  BridgeTests.equal(0xA, client.instance_variable_get(:@outbound).first[0])
  client.close
end

BridgeTests.test("aggregate fragment limit rejects continuation before reading payload") do
  limit = DSHSketchupBridge::WebSocketClient::MAX_MESSAGE_BYTES
  first = "x" * (limit / 2)
  # Deliberately supply just the continuation HEADER, not its oversized payload.
  client = WebSocketFixture.buffered(WebSocketFixture.frame(1, first, false) + WebSocketFixture.header(0, limit / 2 + 1))
  BridgeTests.raises(RuntimeError, /message exceeds/) { client.read_json }
  BridgeTests.equal("", client.instance_variable_get(:@fragments))
  BridgeTests.equal(nil, client.instance_variable_get(:@fragment_opcode))
  client.close
end

BridgeTests.test("exact aggregate limit is accepted") do
  limit = DSHSketchupBridge::WebSocketClient::MAX_MESSAGE_BYTES
  prefix = '"' + ("x" * (limit - 2))
  client = WebSocketFixture.buffered(WebSocketFixture.frame(1, prefix, false) + WebSocketFixture.frame(0, '"'))
  BridgeTests.equal(limit - 2, client.read_json.bytesize)
  client.close
end

BridgeTests.test("overlapping data messages and unsolicited continuations are rejected") do
  client = WebSocketFixture.buffered(WebSocketFixture.frame(1, "{", false) + WebSocketFixture.frame(1, "{}"))
  BridgeTests.raises(RuntimeError, /new text frame/) { client.read_json }
  client.close
  client = WebSocketFixture.buffered(WebSocketFixture.frame(0, "{}"))
  BridgeTests.raises(RuntimeError, /unexpected WebSocket continuation/) { client.read_json }
  client.close
end

BridgeTests.test("masked server frames and invalid UTF-8 fail closed") do
  client = WebSocketFixture.buffered([0x81, 0x80].pack("CC"))
  BridgeTests.raises(RuntimeError, /must not be masked/) { client.read_json }
  client.close
  client = WebSocketFixture.buffered(WebSocketFixture.frame(1, "\"\xff\"".b))
  BridgeTests.raises(RuntimeError, /valid UTF-8/) { client.read_json }
  client.close
end

BridgeTests.test("outbound queue count and byte limits fail without waiting for a writer") do
  client = WebSocketFixture.buffered("")
  DSHSketchupBridge::WebSocketClient::MAX_OUTBOUND_FRAMES.times { client.send_json({}) }
  BridgeTests.raises(RuntimeError, /queue is full/) { client.send_json({}) }
  BridgeTests.equal(false, client.open?)
  BridgeTests.equal([], client.instance_variable_get(:@outbound))

  client = WebSocketFixture.buffered("")
  frame = "x" * DSHSketchupBridge::WebSocketClient::MAX_FRAME_BYTES
  2.times { client.send(:send_frame, 1, frame) }
  BridgeTests.raises(RuntimeError, /queue is full/) { client.send_json({}) }
  BridgeTests.equal(false, client.open?)
end

BridgeTests.test("writer masks client text and handles all length encodings") do
  client = WebSocketFixture.buffered("")
  [0, 125, 126, 65_535, 65_536].each do |length|
    original = "x" * length
    wire = client.send(:encode_frame, 1, original)
    BridgeTests.equal(0x81, wire.getbyte(0))
    BridgeTests.assert((wire.getbyte(1) & 0x80) != 0)
    offset = length < 126 ? 2 : length <= 65_535 ? 4 : 10
    mask = wire.byteslice(offset, 4)
    payload = wire.byteslice(offset + 4..-1)
    decoded = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
    BridgeTests.equal(original, decoded)
  end
  client.close
end

BridgeTests.test("idle peer and partial frame EOF are bounded") do
  WebSocketFixture.socket_pair do |local, remote|
    client = WebSocketFixture.attached(local)
    BridgeTests.raises(Timeout::Error, /read timed out/) { client.read_json }
    remote.write([0x81].pack("C"))
    remote.close
    BridgeTests.raises(RuntimeError, /unexpected end/) { client.read_json }
    client.close
  end
end

BridgeTests.test("write deadline closes a stalled connection on writer thread") do
  WebSocketFixture.socket_pair do |local, _remote|
    local.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)
    client = WebSocketFixture.attached(local, timeout: 0.05)
    client.send(:start_writer)
    # Bytes exceed OS buffering; the peer intentionally never reads.
    client.send_json({ "data" => "x" * (4 * 1024 * 1024) })
    BridgeTests.await(5) { !client.open? }
    writer = client.instance_variable_get(:@writer)
    BridgeTests.assert(writer.join(1), "writer did not terminate after timeout")
  end
end

BridgeTests.test("enqueue does not run socket IO on the calling UI thread") do
  WebSocketFixture.socket_pair do |local, _remote|
    client = WebSocketFixture.attached(local)
    entered = Queue.new
    released = Queue.new
    client.define_singleton_method(:write_all) do |_socket, _bytes|
      entered << Thread.current
      released.pop
    end
    client.send(:start_writer)
    caller = Thread.current
    client.send_json({ "first" => true })
    writer_thread = Timeout.timeout(2) { entered.pop }
    BridgeTests.assert(writer_thread != caller, "socket write ran on UI caller")
    # This must return while the writer is deliberately blocked in write_all.
    Timeout.timeout(0.5) { 10.times { client.send_json({ "queued" => true }) } }
    client.close
    released << true
    BridgeTests.assert(client.instance_variable_get(:@writer).join(1), "writer did not stop")
  ensure
    released << true if released
    client.close if client
  end
end
