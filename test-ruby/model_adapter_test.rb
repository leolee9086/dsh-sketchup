# frozen_string_literal: true
require_relative "test_helper"

class PluginTestManager
  attr_accessor :plugin_write_enabled, :plugin_load_enabled
  def initialize
    @plugin_write_enabled = true
    @plugin_load_enabled = false
  end
  def record_event(*); end
end
class PluginTestAdapter < DSHSketchupBridge::ModelAdapter
  def initialize(manager, root)
    super(manager)
    @test_root = root
  end
  private
  def plugin_root; @test_root; end
end

module PluginFixture
  def self.with_adapter
    Dir.mktmpdir("dsh-ruby-test-") do |base|
      root = File.join(base, "Plugins")
      outside = File.join(base, "outside")
      FileUtils.mkdir_p([root, outside])
      manager = PluginTestManager.new
      yield PluginTestAdapter.new(manager, root), manager, root, outside
    end
  end
  def self.args(extra = {})
    { "pluginId" => "demo", "entryFile" => "demo/main.rb", "code" => "# safe fixture\n", "confirm" => true }.merge(extra)
  end
  def self.link_directory(target, link)
    if File::ALT_SEPARATOR == "\\"
      # Junctions do not require Developer Mode/admin privileges on Windows.
      # Pass one command line: Ruby's argv quoting would otherwise escape the
      # embedded quotes in a single /c argument before cmd interprets them.
      native_link = link.tr("/", "\\")
      native_target = target.tr("/", "\\")
      ok = system("cmd.exe /d /c mklink /J \"#{native_link}\" \"#{native_target}\"", out: File::NULL, err: File::NULL)
      raise "could not create test junction" unless ok
    else
      File.symlink(target, link)
    end
  end
  def self.remove_directory_link(link)
    return unless File.exist?(link) || File.symlink?(link)
    File::ALT_SEPARATOR == "\\" ? Dir.rmdir(link) : File.unlink(link)
  end
end

BridgeTests.test("normal write creates nested directories and replacement backup") do
  PluginFixture.with_adapter do |adapter, _manager, root, _outside|
    args = PluginFixture.args("entryFile" => "demo/nested/main.rb")
    first = adapter.dispatch("sketchup_write_plugin", args)
    target = File.join(root, "demo", "nested", "main.rb")
    BridgeTests.equal(args["code"], File.binread(target))
    BridgeTests.equal(nil, first["backup"])
    second = adapter.dispatch("sketchup_write_plugin", args.merge("code" => "# replacement\n"))
    BridgeTests.equal(args["code"], File.binread(second["backup"]))
    BridgeTests.equal("# replacement\n", File.binread(target))
    BridgeTests.equal([], Dir[File.join(root, "demo", "nested", ".dsh-write-*")])
  end
end

BridgeTests.test("disabled loading fails before an optional-load write changes files") do
  PluginFixture.with_adapter do |adapter, _manager, root, _outside|
    BridgeTests.raises(DSHSketchupBridge::PermissionError, /loading is disabled/) do
      adapter.dispatch("sketchup_write_plugin", PluginFixture.args("load" => true))
    end
    BridgeTests.equal([], Dir.children(root))
  end
end

BridgeTests.test("invalid source does not replace an existing plugin") do
  PluginFixture.with_adapter do |adapter, _manager, _root, _outside|
    saved = adapter.dispatch("sketchup_write_plugin", PluginFixture.args)
    BridgeTests.raises(ArgumentError, /Ruby syntax error/) do
      adapter.dispatch("sketchup_write_plugin", PluginFixture.args("code" => "def unfinished("))
    end
    BridgeTests.equal(PluginFixture.args["code"], File.binread(saved["path"]))
  end
end

BridgeTests.test("traversal, Windows aliases and alternate data streams are rejected") do
  PluginFixture.with_adapter do |adapter, _manager, _root, _outside|
    ["../evil.rb", "/demo/evil.rb", "demo/../evil.rb", "demo//evil.rb", "demo/x:payload.rb",
     "demo/dir./main.rb", "demo/dir /main.rb", "demo/NUL.rb", "demo/COM1/main.rb",
     "demo/evil\x00.rb", "demo.rb", "demo/x.rb/"].each do |entry|
      BridgeTests.raises(ArgumentError) { adapter.send(:safe_plugin_path, "demo", entry) }
    end
  end
end

BridgeTests.test("directory symlink or Windows junction cannot redirect write or reload") do
  PluginFixture.with_adapter do |adapter, manager, root, outside|
    target = File.join(outside, "main.rb")
    File.write(target, "# outside sentinel\n")
    link = File.join(root, "demo")
    begin
      PluginFixture.link_directory(outside, link)
      BridgeTests.raises(ArgumentError, /symbolic link|redirected/) do
        adapter.dispatch("sketchup_write_plugin", PluginFixture.args)
      end
      manager.plugin_load_enabled = true
      BridgeTests.raises(ArgumentError, /symbolic link|redirected/) do
        adapter.dispatch("sketchup_reload_plugin", PluginFixture.args)
      end
      BridgeTests.equal("# outside sentinel\n", File.read(target))
      BridgeTests.equal(["main.rb"], Dir.children(outside))
    ensure
      # Remove only the link, never recursively delete the linked target.
      PluginFixture.remove_directory_link(link)
    end
  end
end

BridgeTests.test("a nested directory link is rejected before creating the missing tail") do
  PluginFixture.with_adapter do |adapter, _manager, root, outside|
    FileUtils.mkdir_p(File.join(root, "demo"))
    link = File.join(root, "demo", "linked")
    begin
      PluginFixture.link_directory(outside, link)
      BridgeTests.raises(ArgumentError, /symbolic link|redirected/) do
        adapter.dispatch("sketchup_write_plugin", PluginFixture.args("entryFile" => "demo/linked/new/main.rb"))
      end
      BridgeTests.equal([], Dir.children(outside))
    ensure
      PluginFixture.remove_directory_link(link)
    end
  end
end

BridgeTests.test("file symlink is rejected including a dangling link") do
  PluginFixture.with_adapter do |adapter, _manager, root, outside|
    FileUtils.mkdir_p(File.join(root, "demo"))
    link = File.join(root, "demo", "main.rb")
    begin
      File.symlink(File.join(outside, "missing.rb"), link)
    rescue NotImplementedError, Errno::EPERM, Errno::EACCES
      # Windows requires Developer Mode/admin for file symlinks. Directory
      # junction coverage above remains mandatory and does not need elevation.
      puts "SKIP file-symlink fixture: operating system disallows creating symlinks"
      next
    end
    BridgeTests.raises(ArgumentError, /symbolic link/) do
      adapter.dispatch("sketchup_write_plugin", PluginFixture.args)
    end
    BridgeTests.equal([], Dir.children(outside))
  end
end

BridgeTests.test("realpath redirection is rejected even when lstat reports a directory") do
  PluginFixture.with_adapter do |adapter, _manager, root, outside|
    demo = File.join(root, "demo")
    FileUtils.mkdir_p(demo)
    original = File.method(:realpath)
    File.define_singleton_method(:realpath) do |path, *args|
      File.expand_path(path) == File.expand_path(demo) ? outside : original.call(path, *args)
    end
    begin
      BridgeTests.raises(ArgumentError, /redirected/) { adapter.send(:safe_plugin_path, "demo", "demo/main.rb") }
    ensure
      File.define_singleton_method(:realpath, original)
    end
  end
end
