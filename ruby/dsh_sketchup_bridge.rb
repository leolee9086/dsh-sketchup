# frozen_string_literal: true

require "sketchup.rb"
require "extensions.rb"
require "time"
require File.join(__dir__, "dsh_sketchup_bridge", "setup")

# Register setup independently of the bridge connection or main extension load.
DSHSketchupBridge::HostSetup.register_menu

module DSHSketchupBridge
  # Startup errors otherwise surface only in SketchUp's Ruby Console. Keep a
  # best-effort local trace so a disabled extension or a load failure can be
  # diagnosed without changing model state.
  def self.boot_log(message)
    File.open(File.join(__dir__, "dsh_sketchup_bridge", "boot.log"), "a") do |file|
      file.puts("#{Time.now.iso8601} #{message}")
    end
  rescue Exception
    # Diagnostic I/O must never prevent SketchUp from loading the extension.
  end

  boot_log("root loader entered")
  unless file_loaded?(__FILE__)
    # SketchUp scans this root loader at startup. The implementation stays in
    # the namespaced directory and is loaded only while the extension is enabled.
    extension = SketchupExtension.new(
      "DSH SketchUp Bridge",
      "dsh_sketchup_bridge/main"
    )
    extension.description = "Connects SketchUp to the local DeepSeek Harness bridge."
    extension.version = "0.1.0-alpha.2"
    extension.creator = "leolee9086; upstream Yuxiang Lin / dsh-browser contributors"

    Sketchup.register_extension(extension, true)
    boot_log("extension registered")
    file_loaded(__FILE__)
  end
end
