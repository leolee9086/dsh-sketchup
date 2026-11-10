# frozen_string_literal: true
require_relative "test_helper"

module PortDiscoveryFixture
  # Each test owns a real temporary discovery file. Restore process state even
  # after an assertion fails; never touch the installed bridge's discovery file.
  def self.with_discovery
    original_env = ENV.delete("DSH_SKETCHUP_PORT")
    original_path = DSHSketchupBridge::DISCOVERY_FILE
    Dir.mktmpdir("dsh-port-discovery-") do |dir|
      path = File.join(dir, "bridge.json")
      DSHSketchupBridge.send(:remove_const, :DISCOVERY_FILE)
      DSHSketchupBridge.const_set(:DISCOVERY_FILE, path)
      yield path
    end
  ensure
    ENV["DSH_SKETCHUP_PORT"] = original_env
    DSHSketchupBridge.send(:remove_const, :DISCOVERY_FILE)
    DSHSketchupBridge.const_set(:DISCOVERY_FILE, original_path)
  end

  def self.read_exact(socket, count)
    data = +"".b
    data << socket.readpartial(count - data.bytesize) while data.bytesize < count
    data
  end

  def self.accept_hello(listener)
    socket = listener.accept
    headers = +""
    headers << socket.readpartial(1) until headers.end_with?("\r\n\r\n")
    key = headers[/Sec-WebSocket-Key: ([^\r\n]+)/, 1]
    BridgeTests.assert(key, "missing WebSocket upgrade key")
    accept = Base64.strict_encode64(Digest::SHA1.digest(key + DSHSketchupBridge::WebSocketClient::WEBSOCKET_GUID))
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
    first, second = read_exact(socket, 2).bytes
    BridgeTests.equal(0x81, first)
    BridgeTests.assert((second & 0x80) != 0, "client frame must be masked")
    length = second & 0x7f
    length = read_exact(socket, 2).unpack1("n") if length == 126
    length = read_exact(socket, 8).unpack1("Q>") if length == 127
    mask = read_exact(socket, 4)
    payload = read_exact(socket, length)
    decoded = payload.bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*")
    yield socket, JSON.parse(decoded)
  ensure
    socket.close if socket && !socket.closed?
  end
end

BridgeTests.test("discovery changes are read on the next resolution without reloading Ruby") do
  PortDiscoveryFixture.with_discovery do |path|
    File.write(path, JSON.generate({ "port" => 64001 }))
    BridgeTests.equal(64001, DSHSketchupBridge.connection_port)
    File.write(path, JSON.generate({ "port" => 64002 }))
    BridgeTests.equal(64002, DSHSketchupBridge.connection_port)
  end
end

BridgeTests.test("explicit port override wins and empty override restores discovery") do
  PortDiscoveryFixture.with_discovery do |path|
    File.write(path, JSON.generate({ "port" => 64003 }))
    ENV["DSH_SKETCHUP_PORT"] = "64004"
    BridgeTests.equal(64004, DSHSketchupBridge.connection_port)
    ENV["DSH_SKETCHUP_PORT"] = ""
    BridgeTests.equal(64003, DSHSketchupBridge.connection_port)
    ENV["DSH_SKETCHUP_PORT"] = "invalid"
    BridgeTests.equal(3080, DSHSketchupBridge.connection_port)
  end
end

BridgeTests.test("missing malformed and out of range discovery use the fallback port") do
  PortDiscoveryFixture.with_discovery do |path|
    BridgeTests.equal(3080, DSHSketchupBridge.connection_port)
    ["{", "null", "[]", '{}', '{"port":0}', '{"port":65536}', '{"port":"64000"}'].each do |content|
      File.write(path, content)
      BridgeTests.equal(3080, DSHSketchupBridge.connection_port)
    end
  end
end

BridgeTests.test("real manager reconnect follows a changed discovery port and keeps its identity") do
  PortDiscoveryFixture.with_discovery do |path|
    first = TCPServer.new("127.0.0.1", 0)
    second = TCPServer.new("127.0.0.1", 0)
    File.write(path, JSON.generate({ "port" => first.addr[1] }))
    manager = DSHSketchupBridge::Manager.new
    generation = Object.new
    manager.instance_variable_set(:@running, true)
    manager.instance_variable_set(:@run_generation, generation)
    worker = Thread.new { manager.send(:connection_loop, generation) }
    Timeout.timeout(6) do
      PortDiscoveryFixture.accept_hello(first) do |_socket, hello|
        BridgeTests.equal(manager.instance_id, hello.fetch("caps").fetch("instanceId"))
        File.write(path, JSON.generate({ "port" => second.addr[1] }))
        # Closing the first socket simulates Harness going away.
      end
      PortDiscoveryFixture.accept_hello(second) do |_socket, hello|
        BridgeTests.equal(manager.instance_id, hello.fetch("caps").fetch("instanceId"))
        BridgeTests.equal(second.addr[1], manager.instance_variable_get(:@connection_port))
        manager.instance_variable_set(:@running, false)
        manager.instance_variable_set(:@run_generation, nil)
      end
      BridgeTests.assert(worker.join(2), "manager worker failed to finish")
    end
  ensure
    manager.instance_variable_set(:@running, false) if manager
    client = manager.instance_variable_get(:@client) if manager
    client.close if client
    worker.kill if worker && worker.alive?
    worker.join if worker
    first.close if first && !first.closed?
    second.close if second && !second.closed?
  end
end
