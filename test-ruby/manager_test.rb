# frozen_string_literal: true
require_relative "test_helper"

class FakeBridgeClient
  attr_reader :sent
  def initialize
    @open = true
    @sent = []
  end
  def open?; @open; end
  def close; @open = false; end
  def send_json(value)
    raise "closed socket" unless open?
    @sent << value
  end
end

class FakeModelAdapter
  attr_reader :calls
  attr_accessor :during_dispatch
  def initialize; @calls = []; end
  def dispatch(name, args)
    @calls << [name, args]
    @during_dispatch.call if @during_dispatch
    { "text" => "done" }
  end
end

module ManagerFixture
  def self.attach(manager, client)
    manager.instance_variable_set(:@running, true)
    manager.instance_variable_set(:@client, client)
    manager.instance_variable_set(:@connected, true)
  end
  def self.build
    manager = DSHSketchupBridge::Manager.new
    adapter = FakeModelAdapter.new
    manager.instance_variable_set(:@adapter, adapter)
    client = FakeBridgeClient.new
    attach(manager, client)
    [manager, adapter, client]
  end
  def self.call(id = "call-1")
    { "t" => "tool.call", "id" => id, "name" => "sketchup_execute",
      "args" => { "operation" => "erase_selection" }, "expiresAt" => Time.now.to_f * 1000 + 10_000 }
  end
end

BridgeTests.test("current client executes once and receives its result") do
  manager, adapter, client = ManagerFixture.build
  frame = ManagerFixture.call
  2.times { manager.send(:handle_server_frame, client, frame) }
  manager.send(:drain_queue)
  BridgeTests.equal(1, adapter.calls.length)
  BridgeTests.equal(1, client.sent.length)
  BridgeTests.equal(true, client.sent[0]["ok"])
end

BridgeTests.test("disconnect purges queued edits and cancellation state before reconnect") do
  manager, adapter, first = ManagerFixture.build
  manager.send(:handle_server_frame, first, ManagerFixture.call)
  manager.send(:disconnect_client, first)
  BridgeTests.equal([], manager.instance_variable_get(:@queue))
  BridgeTests.equal({}, manager.instance_variable_get(:@cancelled))
  second = FakeBridgeClient.new
  ManagerFixture.attach(manager, second)
  manager.send(:drain_queue)
  BridgeTests.equal([], adapter.calls)
  BridgeTests.equal([], second.sent)
end

BridgeTests.test("already-drained batch cannot execute after its source disconnects") do
  manager, adapter, first = ManagerFixture.build
  frame = ManagerFixture.call
  manager.send(:handle_server_frame, first, frame)
  batch = manager.instance_variable_get(:@queue).dup
  manager.send(:disconnect_client, first)
  second = FakeBridgeClient.new
  ManagerFixture.attach(manager, second)
  batch.each { |source, value| manager.send(:process_tool_call, source, value) }
  BridgeTests.equal([], adapter.calls)
  BridgeTests.equal([], second.sent)
end

BridgeTests.test("closed writer socket invalidates work before reader cleanup") do
  manager, adapter, client = ManagerFixture.build
  manager.send(:handle_server_frame, client, ManagerFixture.call)
  client.close
  manager.send(:drain_queue)
  BridgeTests.equal([], adapter.calls)
end

BridgeTests.test("result and error never leak to replacement connection") do
  [false, true].each do |fail_dispatch|
    manager, adapter, first = ManagerFixture.build
    second = FakeBridgeClient.new
    adapter.during_dispatch = lambda do
      manager.send(:disconnect_client, first)
      ManagerFixture.attach(manager, second)
      raise ArgumentError, "fixture failure" if fail_dispatch
    end
    manager.send(:handle_server_frame, first, ManagerFixture.call)
    manager.send(:drain_queue)
    BridgeTests.equal(1, adapter.calls.length)
    BridgeTests.equal([], second.sent)
  end
end

BridgeTests.test("cancellation ids are scoped to their source socket") do
  manager, adapter, first = ManagerFixture.build
  frame = ManagerFixture.call
  manager.send(:handle_server_frame, first, frame)
  manager.send(:handle_server_frame, first, { "t" => "tool.cancel", "id" => frame["id"] })
  manager.send(:drain_queue)
  BridgeTests.equal([], adapter.calls)
  BridgeTests.equal(false, first.sent.last["ok"])
  manager.send(:disconnect_client, first)
  second = FakeBridgeClient.new
  ManagerFixture.attach(manager, second)
  manager.send(:handle_server_frame, second, frame)
  # A late cancel from the retired socket must not cancel the same id on B.
  manager.send(:handle_server_frame, first, { "t" => "tool.cancel", "id" => frame["id"] })
  manager.send(:drain_queue)
  BridgeTests.equal(1, adapter.calls.length)
end

BridgeTests.test("unknown cancellation ids do not grow retained state") do
  manager, _adapter, client = ManagerFixture.build
  300.times { |index| manager.send(:handle_server_frame, client, { "t" => "tool.cancel", "id" => "unknown-#{index}" }) }
  BridgeTests.equal({}, manager.instance_variable_get(:@cancelled))
end

BridgeTests.test("disconnecting old socket does not erase a new client's queued edit") do
  manager, adapter, first = ManagerFixture.build
  second = FakeBridgeClient.new
  ManagerFixture.attach(manager, second)
  manager.send(:handle_server_frame, second, ManagerFixture.call)
  manager.send(:disconnect_client, first)
  manager.send(:drain_queue)
  BridgeTests.equal(1, adapter.calls.length)
  BridgeTests.equal(true, second.sent.last["ok"])
end

BridgeTests.test("expired or missing expiry never executes") do
  [nil, 1].each do |expiry|
    manager, adapter, client = ManagerFixture.build
    manager.send(:handle_server_frame, client, ManagerFixture.call.merge("expiresAt" => expiry))
    manager.send(:drain_queue)
    BridgeTests.equal([], adapter.calls)
    BridgeTests.equal(false, client.sent.last["ok"])
  end
end

BridgeTests.test("bounded inbound queue disconnects and drops accumulated edits") do
  manager, adapter, client = ManagerFixture.build
  (DSHSketchupBridge::Manager::MAX_QUEUED_TOOLS + 1).times do |index|
    manager.send(:handle_server_frame, client, ManagerFixture.call("id-#{index}"))
  end
  BridgeTests.equal(false, client.open?)
  manager.send(:drain_queue)
  BridgeTests.equal([], adapter.calls)
end
