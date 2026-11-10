# frozen_string_literal: true
require_relative "test_helper"
require_relative "manager_test"

module RubyFixture
  def self.build
    manager = DSHSketchupBridge::Manager.new
    manager.instance_variable_set(:@host_caps, { "rubyExecuteEnabled" => true })
    [manager, DSHSketchupBridge::ModelAdapter.new(manager)]
  end
  def self.args(manager, code = "1 + 1")
    { "code" => code, "confirm" => true, "expectedInstanceId" => manager.instance_id }
  end
end

BridgeTests.test("Ruby opt-in is absent or false on legacy Hosts") do
  manager = DSHSketchupBridge::Manager.new
  BridgeTests.equal(false, manager.ruby_execute_enabled)
  [nil, {}, { "rubyExecuteEnabled" => false }, { "rubyExecuteEnabled" => "true" }].each do |caps|
    manager.instance_variable_set(:@host_caps, caps)
    BridgeTests.equal(false, manager.ruby_execute_enabled)
  end
end

BridgeTests.test("Ruby requires confirmation, deployment gate and exact target") do
  manager, adapter = RubyFixture.build
  args = RubyFixture.args(manager)
  [false, nil, "true"].each do |confirmation|
    BridgeTests.raises(ArgumentError) { adapter.dispatch("sketchup_ruby", args.merge("confirm" => confirmation)) }
  end
  [nil, "", "sketchup-wrong"].each do |identity|
    BridgeTests.raises(DSHSketchupBridge::PermissionError) { adapter.dispatch("sketchup_ruby", args.merge("expectedInstanceId" => identity)) }
  end
  manager.instance_variable_set(:@host_caps, {})
  BridgeTests.raises(DSHSketchupBridge::PermissionError) { adapter.dispatch("sketchup_ruby", args) }
end

BridgeTests.test("Ruby validates code bytes and diagnostic filename without executing") do
  manager, adapter = RubyFixture.build
  [nil, "", "  ", "汉" * 400_000, "\xff".b.force_encoding("UTF-8")].each do |code|
    BridgeTests.raises(ArgumentError) { adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, code)) }
  end
  ["", "a\n.rb", "a\x00.rb", "汉" * 400, 123].each do |filename|
    BridgeTests.raises(ArgumentError) { adapter.dispatch("sketchup_ruby", RubyFixture.args(manager).merge("filename" => filename)) }
  end
end

BridgeTests.test("Ruby returns typed result, stdout, stderr and correct identity") do
  manager, adapter = RubyFixture.build
  before = [$stdout, $stderr]
  payload = adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, 'puts "门表"; warn "diagnostic"; {"answer" => 42, "ok" => true, "nil" => nil}'))
  BridgeTests.equal(true, payload["success"])
  BridgeTests.equal(manager.instance_id, payload["instanceId"])
  BridgeTests.equal(Process.pid, payload["processId"])
  BridgeTests.equal({ "answer" => 42, "ok" => true, "nil" => nil }, payload["result"])
  BridgeTests.equal("门表\n", payload["stdout"])
  BridgeTests.assert(payload["stderr"].include?("diagnostic"))
  BridgeTests.equal(before, [$stdout, $stderr])
end

BridgeTests.test("Ruby failures preserve output and always restore Ruby streams") do
  manager, adapter = RubyFixture.build
  { 'puts "before"; raise "failure"' => "RuntimeError", 'def broken(' => "SyntaxError", 'exit 7' => "SystemExit" }.each do |code, klass|
    before = [$stdout, $stderr]
    payload = adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, code).merge("filename" => "door-probe.rb"))
    BridgeTests.equal(false, payload["success"])
    BridgeTests.equal(klass, payload["error"]["class"])
    BridgeTests.equal(before, [$stdout, $stderr])
    BridgeTests.assert(payload["stdout"].include?("before")) if klass == "RuntimeError"
  end
end

BridgeTests.test("Ruby output capture is bounded and remains valid UTF8") do
  manager, adapter = RubyFixture.build
  payload = adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, 'print "门" * 100_000; $stderr.write("x" * 100_000); nil'))
  BridgeTests.equal(true, payload["stdoutTruncated"])
  BridgeTests.equal(true, payload["stderrTruncated"])
  ["stdout", "stderr"].each do |key|
    BridgeTests.assert(payload[key].valid_encoding?)
    BridgeTests.assert(payload[key].bytesize <= DSHSketchupBridge::RubyExecution::MAX_OUTPUT_BYTES)
  end
  BridgeTests.equal(300_000, payload["stdoutBytes"])
end

BridgeTests.test("Ruby cyclic and unsupported return values do not poison transport") do
  manager, adapter = RubyFixture.build
  payload = adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, 'a=[]; a << a; {"cycle" => a, "object" => Object.new, "nan" => Float::NAN}'))
  BridgeTests.equal(true, payload["success"])
  BridgeTests.equal(true, payload["resultCoerced"])
  BridgeTests.assert(JSON.generate(payload).include?("Circular"))
end

BridgeTests.test("Ruby result conversion bounds nested nodes and large strings") do
  manager, adapter = RubyFixture.build
  ['"门" * 100_000', 'Array.new(100_000, 1)', 'a=[]; 30.times { a=[a] }; a'].each do |code|
    payload = adapter.dispatch("sketchup_ruby", RubyFixture.args(manager, code))
    BridgeTests.equal(true, payload["success"])
    BridgeTests.equal(true, payload["resultTruncated"])
    BridgeTests.assert(JSON.generate(payload["result"]).bytesize <= DSHSketchupBridge::RubyExecution::MAX_RESULT_BYTES)
  end
end

BridgeTests.test("queued Ruby cancellation and expiry prevent script side effects") do
  [:expired, :cancelled].each do |mode|
    manager, _adapter, client = ManagerFixture.build
    manager.instance_variable_set(:@host_caps, { "rubyExecuteEnabled" => true })
    manager.instance_variable_set(:@adapter, DSHSketchupBridge::ModelAdapter.new(manager))
    $dsh_ruby_test_executed = false
    frame = ManagerFixture.call.merge("name" => "sketchup_ruby", "args" => RubyFixture.args(manager, '$dsh_ruby_test_executed = true'))
    frame["expiresAt"] = 1 if mode == :expired
    manager.send(:handle_server_frame, client, frame)
    manager.send(:handle_server_frame, client, { "t" => "tool.cancel", "id" => frame["id"] }) if mode == :cancelled
    manager.send(:drain_queue)
    BridgeTests.equal(false, $dsh_ruby_test_executed)
    BridgeTests.equal(false, client.sent.last["ok"])
  end
ensure
  $dsh_ruby_test_executed = nil
end

BridgeTests.test("Ruby runs only during UI queue drain and transmits script errors intact") do
  manager, _adapter, client = ManagerFixture.build
  manager.instance_variable_set(:@host_caps, { "rubyExecuteEnabled" => true })
  manager.instance_variable_set(:@adapter, DSHSketchupBridge::ModelAdapter.new(manager))
  $dsh_ruby_test_executed = false
  frame = ManagerFixture.call.merge("name" => "sketchup_ruby", "args" => RubyFixture.args(manager, '$dsh_ruby_test_executed = true; puts "queued"; raise "expected"'))
  manager.send(:handle_server_frame, client, frame)
  BridgeTests.equal(false, $dsh_ruby_test_executed)
  manager.send(:drain_queue)
  BridgeTests.equal(true, $dsh_ruby_test_executed)
  BridgeTests.equal(true, client.sent.last["ok"])
  BridgeTests.equal(false, client.sent.last["result"]["success"])
  BridgeTests.equal("queued\n", client.sent.last["result"]["stdout"])
ensure
  $dsh_ruby_test_executed = nil
end

BridgeTests.test("reloading main preserves live manager identity adapter and queue") do
  manager = DSHSketchupBridge.manager
  identity = manager.instance_id
  adapter = manager.instance_variable_get(:@adapter)
  queue = manager.instance_variable_get(:@queue)
  verbose = $VERBOSE
  begin
    $VERBOSE = nil # constants are deliberately reopened during plugin reload
    load File.expand_path("../ruby/dsh_sketchup_bridge/main.rb", __dir__)
  ensure
    $VERBOSE = verbose
  end
  BridgeTests.assert(manager.equal?(DSHSketchupBridge.manager))
  BridgeTests.equal(identity, DSHSketchupBridge.manager.instance_id)
  BridgeTests.assert(adapter.equal?(manager.instance_variable_get(:@adapter)))
  BridgeTests.assert(queue.equal?(manager.instance_variable_get(:@queue)))
end
