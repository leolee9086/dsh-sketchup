# frozen_string_literal: true

# No SketchUp installation or gems required. Run: ruby test-ruby/run.rb
# These mocks deliberately refuse to run inside the real SketchUp interpreter.
require "tmpdir"
require "fileutils"
require "stringio"
require "socket"
require "timeout"
raise "Run these tests in standalone Ruby, never inside SketchUp" if defined?(Sketchup)

module Sketchup
  class ModelObserver; end
  class EntitiesObserver; end
  class SelectionObserver; end
  class AppObserver; end
end
module DSHSketchupBridge
  def self.boot_log(_message); end
end
# main.rb's installation guard skips menus/timers/worker startup in these tests.
def file_loaded?(_path)
  true
end
require_relative "../ruby/dsh_sketchup_bridge/main"

module BridgeTests
  @tests = []
  def self.test(name, &block)
    @tests << [name, block]
  end
  def self.assert(value, message = "assertion failed")
    raise message unless value
  end
  def self.equal(expected, actual)
    assert(expected == actual, "expected #{expected.inspect}, got #{actual.inspect}")
  end
  def self.raises(type = StandardError, matching = nil)
    begin
      yield
    rescue type => error
      assert(error.message.match?(matching), "unexpected error: #{error.message}") if matching
      return error
    end
    raise "expected #{type}"
  end
  def self.await(timeout = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition did not settle within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.005)
    end
  end
  def self.run
    failures = []
    @tests.each do |name, block|
      begin
        block.call
        puts "PASS #{name}"
      rescue Exception => error
        failures << name
        warn "FAIL #{name}: #{error.class}: #{error.message}\n  #{error.backtrace.first(5).join("\n  ")}"
      end
    end
    puts "#{@tests.length} tests, #{failures.length} failures"
    exit(failures.empty? ? 0 : 1)
  end
end
