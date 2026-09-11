# frozen_string_literal: true
require_relative "test_helper"
Dir[File.join(__dir__, "*_test.rb")].sort.each { |path| require path }
BridgeTests.run
