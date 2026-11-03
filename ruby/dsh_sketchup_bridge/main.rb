# frozen_string_literal: true

# Manager and SketchUp observers for the local DSH bridge. The important
# threading rule is simple: socket I/O happens on a worker thread, while every
# SketchUp API call is queued and drained by a repeating UI timer.
require "json"
require "securerandom"
require "time"
require File.join(__dir__, "websocket_client")
begin
  require File.join(__dir__, "model_adapter")
rescue Exception => error
  DSHSketchupBridge.boot_log("model_adapter load failed: #{error.class}: #{error.message}")
  raise
end
DSHSketchupBridge.boot_log("main loaded")

module DSHSketchupBridge
  VERSION = "0.1.0"
  HOST = ENV.fetch("DSH_SKETCHUP_HOST", "127.0.0.1")
  # The Host listens on the DSH web server port, which is not fixed. It writes
  # that port to a discovery file; the environment variable stays as an override.
  DISCOVERY_FILE = begin
    local = ENV["LOCALAPPDATA"]
    if local.nil? || local.empty?
      File.join(Dir.home, ".dsh-sketchup", "bridge.json")
    else
      File.join(local, "dsh-sketchup", "bridge.json")
    end
  end
  PORT = begin
    configured = ENV["DSH_SKETCHUP_PORT"]
    configured = nil if configured && configured.empty?
    if configured
      Integer(configured, 10)
    else
      discovered = begin
        JSON.parse(File.read(DISCOVERY_FILE))["port"]
      rescue Exception
        nil
      end
      discovered.is_a?(Integer) && discovered.positive? ? discovered : 3080
    end
  rescue ArgumentError
    3080
  end
  PATH = "/ext/sketchup"
  MAX_HISTORY_EVENTS = 200
  MAX_EVENT_PAYLOAD_BYTES = 64 * 1024
  RECONNECT_MAX_SECONDS = 10

  # A small exception class lets the tool result distinguish a deliberate local
  # permission refusal from a malformed command or an unexpected API failure.
  class PermissionError < StandardError
  end

  class Manager
    MAX_QUEUED_TOOLS = 256

    attr_reader :max_history_events, :instance_id

    def initialize
      @max_history_events = MAX_HISTORY_EVENTS
      # One id per Manager lifetime. Reconnects keep the same identity, while a
      # fresh SketchUp process receives a new id for multi-instance routing.
      @instance_id = "sketchup-#{SecureRandom.uuid}"
      @history = []
      @next_sequence = 1
      @history_mutex = Mutex.new
      @queue = []
      @queue_mutex = Mutex.new
      @cancelled = {}
      @running = false
      @run_generation = nil
      @connected = false
      @client = nil
      @client_mutex = Mutex.new
      @worker = nil
      @timer_id = nil
      @model = nil
      @model_observer = nil
      @entities_observer = nil
      @selection_observer = nil
      @app_observer = nil
      @selection_signature = nil
      @host_caps = nil
      @sketchup_version = nil
      @chat_dialog = nil
      @operation_names = []
      @adapter = ModelAdapter.new(self)
    end

    def running?
      @running
    end

    # The Host advertises these deployment policy switches in hello.ok. The
    # Ruby side deliberately does not duplicate them in environment variables;
    # the two processes already share the accepted local handshake.
    def plugin_write_enabled
      @host_caps.is_a?(Hash) && @host_caps["pluginWriteEnabled"] == true
    end

    def plugin_load_enabled
      @host_caps.is_a?(Hash) && @host_caps["pluginLoadEnabled"] == true
    end

    # Start is called on SketchUp's UI thread by the loader timer or menu.
    def start
      return if @running
      @running = true
      run_generation = Object.new
      @run_generation = run_generation
      @sketchup_version = safe_string(Sketchup, :version)
      @app_observer = AppObserver.new(self)
      Sketchup.add_observer(@app_observer)
      @timer_id = UI.start_timer(0.05, true) { drain_queue }
      UI.start_timer(0.1, false) { attach_model(Sketchup.active_model) }
      @worker = Thread.new { connection_loop(run_generation) }
      log("started; target ws://#{HOST}:#{PORT}#{PATH}")
    rescue Exception => error
      @running = false
      @run_generation = nil
      log("start failed: #{error.class}: #{error.message}")
    end

    # Stop releases observers and closes the socket. The worker notices the
    # running flag and exits without blocking SketchUp's UI thread.
    def stop
      return unless @running || @client
      @running = false
      @run_generation = nil
      if @timer_id
        UI.stop_timer(@timer_id)
        @timer_id = nil
      end
      detach_model
      if @app_observer
        Sketchup.remove_observer(@app_observer)
        @app_observer = nil
      end
      client = current_client
      client.close unless client.nil?
      @client_mutex.synchronize do
        @client = nil
        @connected = false
        @host_caps = nil
      end
      @queue_mutex.synchronize do
        @queue.clear
        @cancelled.clear
      end
      log("stopped")
    rescue Exception => error
      log("stop failed: #{error.class}: #{error.message}")
    end

    def toggle
      running? ? stop : start
    end

    # Open the reusable DSH WebView surface. The Host route performs the normal
    # process-token exchange; this native side supplies only its instance id.
    def open_chat(attempt = 0)
      start unless running?
      if @chat_dialog
        @chat_dialog.show
        return
      end
      unless connected?
        if attempt < 50
          UI.start_timer(0.1, false) { open_chat(attempt + 1) }
          return
        end
        UI.messagebox("DSH SketchUp bridge is not connected to the Web app.")
        return
      end
      properties = {
        :dialog_title => "DSH SketchUp - #{short_instance_id}",
        :scrollable => true,
        :resizable => true,
        :width => 1100,
        :height => 780
      }
      dialog = UI::HtmlDialog.new(properties)
      @chat_dialog = dialog
      dialog.set_on_closed do
        @chat_dialog = nil if @chat_dialog.equal?(dialog)
      end
      url = "http://#{HOST}:#{PORT}/ext/sketchup-chat?instanceId=#{instance_id}"
      dialog.set_url(url)
      dialog.center
      dialog.show
    rescue Exception => error
      @chat_dialog = nil
      log("chat window failed: #{error.class}: #{error.message}")
      UI.messagebox("DSH SketchUp chat could not open: #{error.message}")
    end

    def status_text
      queue_size = @queue_mutex.synchronize { @queue.length }
      history_size = @history_mutex.synchronize { @history.length }
      state = if !@running
                "stopped"
              elsif @connected
                "connected"
              else
                "connecting"
              end
      "DSH SketchUp bridge #{state}; instance=#{short_instance_id}; #{HOST}:#{PORT}; queued=#{queue_size}; history=#{history_size}; " \
        + "plugin_write=#{plugin_write_enabled}; plugin_load=#{plugin_load_enabled}"
    end

    def short_instance_id
      prefix = "sketchup-"
      instance_id.start_with?(prefix) ? instance_id[prefix.length, 8] : instance_id[0, 8]
    end

    # The adapter calls these accessors only on the UI thread.
    def history(limit)
      count = [[limit.to_i, 1].max, @max_history_events].min
      @history_mutex.synchronize { @history.last(count).map(&:dup) }
    end

    def clear_history
      @history_mutex.synchronize { @history.clear }
    end

    # Keep the DSH command label visible to the transaction observer. SketchUp
    # does not expose a portable native operation-name accessor, but callbacks
    # for a command created by this bridge occur while this scope is active.
    def with_operation(name)
      @operation_names << name.to_s
      yield
    ensure
      @operation_names.pop
    end

    def current_operation_name
      @operation_names.last
    end

    # Record an event even while DSH is offline. The local ring buffer is the
    # authoritative history queried by sketchup_history; the wire event is a
    # live mirror for the Host and is intentionally best-effort.
    def record_event(name, payload)
      safe_payload = bounded_payload(payload)
      event = nil
      @history_mutex.synchronize do
        event = {
          "seq" => @next_sequence,
          "at" => Time.now.to_f,
          "name" => name.to_s,
          "payload" => safe_payload
        }
        @next_sequence += 1
        @history << event
        @history.shift while @history.length > @max_history_events
      end
      send_event(event) unless event.nil?
      event
    rescue Exception => error
      log("event record failed: #{error.class}: #{error.message}")
      nil
    end

    def transaction(kind, model)
      payload = {
        "kind" => kind,
        "modelPath" => safe_string(model, :path),
        "selectionCount" => safe_integer(model.selection, :length)
      }
      operation_name = current_operation_name || safe_string(model, :operation_name)
      payload["operationName"] = operation_name unless operation_name.nil? || operation_name.empty?
      record_event("transaction.#{kind}", payload)
    end

    def entity_added(entity)
      record_event("entity.added", entity_payload(entity))
    end

    def entity_modified(entity)
      record_event("entity.modified", entity_payload(entity))
    end

    def entity_removed(entity_id)
      record_event("entity.removed", { "entityId" => entity_id.to_i })
    end

    def selection_changed(selection)
      ids = selection.to_a.filter_map { |entity| safe_integer(entity, :persistent_id) }.sort
      signature = ids.join(",")
      return if signature == @selection_signature
      @selection_signature = signature
      record_event("selection.changed", { "persistentIds" => ids, "count" => ids.length })
    rescue Exception => error
      log("selection event failed: #{error.class}: #{error.message}")
    end

    def attach_model(model)
      return if model.nil? || @model.equal?(model)
      detach_model
      @model = model
      @model_observer = ModelObserver.new(self)
      @entities_observer = EntitiesObserver.new(self)
      @selection_observer = SelectionObserver.new(self)
      model.add_observer(@model_observer)
      model.entities.add_observer(@entities_observer)
      model.selection.add_observer(@selection_observer)
      @selection_signature = nil
      record_event("model.attached", { "path" => safe_string(model, :path), "title" => safe_string(model, :title) })
    rescue Exception => error
      log("model observer attach failed: #{error.class}: #{error.message}")
    end

    def detach_model(model = @model)
      return if model.nil?
      begin
        model.remove_observer(@model_observer) unless @model_observer.nil?
        model.entities.remove_observer(@entities_observer) unless @entities_observer.nil?
        model.selection.remove_observer(@selection_observer) unless @selection_observer.nil?
      rescue Exception => error
        log("model observer detach failed: #{error.class}: #{error.message}")
      ensure
        @model = nil if @model.equal?(model)
        @model_observer = nil
        @entities_observer = nil
        @selection_observer = nil
        @selection_signature = nil
      end
    end

    def model_closed(model)
      record_event("model.closed", { "path" => safe_string(model, :path) })
      detach_model(model)
    end

    private

    def connection_loop(run_generation)
      delay = 1
      while active_run?(run_generation)
        client = nil
        begin
          client = WebSocketClient.new(host: HOST, port: PORT, path: PATH)
          log("connecting")
          client.connect
          log("WebSocket upgrade complete")
          accepted = @client_mutex.synchronize do
            if active_run?(run_generation)
              @client = client
              @connected = false
              @host_caps = nil
              true
            else
              false
            end
          end
          break unless accepted
          client.send_json(hello_frame)
          log("hello sent")
          delay = 1
          while active_run?(run_generation) && current_client?(client)
            frame = client.read_json
            break if frame.nil?
            handle_server_frame(client, frame)
          end
        rescue Exception => error
          log("connection error: #{error.class}: #{error.message}") if active_run?(run_generation)
        ensure
          disconnect_client(client) unless client.nil?
        end
        break unless active_run?(run_generation)
        sleep(delay)
        delay = [delay * 2, RECONNECT_MAX_SECONDS].min
      end
    end

    def hello_frame
      {
        "t" => "hello",
        "caps" => {
          "client" => "sketchup-ruby",
          "protocol" => 1,
          "instanceId" => @instance_id,
          "sketchupVersion" => @sketchup_version,
          "rubyVersion" => RUBY_VERSION,
          "features" => [
            "snapshot",
            "selection",
            "history",
            "query",
            "structured-operations",
            "plugin-write",
            "plugin-reload"
          ]
        }
      }
    end

    # Invalidate first, then close IO and purge only this socket's work. Another
    # worker from a stop/start cycle must not clear a newer connection's queue.
    def disconnect_client(client)
      @client_mutex.synchronize do
        if @client.equal?(client)
          @client = nil
          @connected = false
          @host_caps = nil
        end
      end
      client.close
      @queue_mutex.synchronize do
        @queue.delete_if { |source, _frame| source.equal?(client) }
        @cancelled.delete_if { |key, _value| key[0].equal?(client) }
      end
    end

    def handle_server_frame(client, frame)
      return unless frame.is_a?(Hash) && current_client?(client)
      case frame["t"]
      when "hello.ok"
        @client_mutex.synchronize do
          return unless @client.equal?(client)
          @connected = true
          @host_caps = frame["caps"]
        end
        record_event("bridge.connected", { "hostCaps" => @host_caps || {} })
        log("connected")
      when "ping"
        client.send_json({ "t" => "pong" })
      when "tool.call"
        enqueue_tool(client, frame) if ready_client?(client)
      when "tool.cancel"
        key = [client, frame["id"].to_s]
        # Ignore unknown/completed ids instead of retaining cancellations forever.
        @queue_mutex.synchronize { @cancelled[key] = true if @cancelled.key?(key) }
      when "error"
        log("Host error #{frame["code"]}: #{frame["message"]}")
      end
    rescue Exception => error
      log("frame handling failed: #{error.class}: #{error.message}")
    end

    def enqueue_tool(client, frame)
      id = frame["id"].to_s
      return if id.empty?
      key = [client, id]
      overflow = @queue_mutex.synchronize do
        return if @cancelled.key?(key)
        if @queue.length >= MAX_QUEUED_TOOLS
          true
        else
          @cancelled[key] = false
          @queue << [client, frame]
          false
        end
      end
      disconnect_client(client) if overflow
    end

    def drain_queue
      batch = @queue_mutex.synchronize do
        value = @queue
        @queue = []
        value
      end
      batch.each { |client, frame| process_tool_call(client, frame) }
    rescue Exception => error
      log("UI queue failed: #{error.class}: #{error.message}")
    end

    def process_tool_call(client, frame)
      id = frame["id"].to_s
      key = [client, id]
      begin
        # Test at dispatch time as well as enqueue time: a timer may already
        # have taken its batch when the reader detects a disconnect. Once native
        # execution starts it cannot be interrupted or rolled back by transport.
        return unless ready_client?(client)
        if expired?(frame) || cancelled?(key)
          send_tool_error(client, id, "bridge-closed", "SketchUp tool call expired or was cancelled")
          return
        end
        args = frame["args"].is_a?(Hash) ? frame["args"] : {}
        result = @adapter.dispatch(frame["name"].to_s, args)
        if cancelled?(key)
          send_tool_error(client, id, "bridge-closed", "SketchUp tool call was cancelled")
        else
          send_tool_result(client, id, result)
        end
      rescue PermissionError => error
        send_tool_error(client, id, "not-enabled", error.message)
      rescue ArgumentError => error
        send_tool_error(client, id, "bad-args", error.message)
      rescue Exception => error
        send_tool_error(client, id, "action-failed", "#{error.class}: #{error.message}")
        log("tool #{frame["name"]} failed: #{error.class}: #{error.message}")
      ensure
        @queue_mutex.synchronize { @cancelled.delete(key) }
      end
    end

    def expired?(frame)
      value = frame["expiresAt"]
      !value.is_a?(Numeric) || !value.finite? || Time.now.to_f * 1000 >= value.to_f
    end

    def cancelled?(key)
      @queue_mutex.synchronize { @cancelled[key] == true }
    end

    def ready_client?(client)
      @client_mutex.synchronize do
        @running && @connected && !client.nil? && @client.equal?(client) && client.open?
      end
    end

    def send_tool_result(client, id, result)
      return unless ready_client?(client)
      client.send_json({ "t" => "tool.result", "id" => id, "ok" => true, "result" => result })
    rescue Exception => error
      log("tool result send failed: #{error.class}: #{error.message}")
    end

    def send_tool_error(client, id, code, message)
      return unless ready_client?(client)
      client.send_json({ "t" => "tool.result", "id" => id, "ok" => false, "error" => { "code" => code, "message" => message } })
    rescue Exception => error
      log("tool error send failed: #{error.class}: #{error.message}")
    end

    def send_event(event)
      client = current_client
      return if client.nil? || !connected?
      client.send_json({
        "t" => "event",
        "seq" => event["seq"],
        "at" => event["at"],
        "name" => event["name"],
        "payload" => event["payload"]
      })
    rescue Exception => error
      log("event send failed: #{error.class}: #{error.message}")
    end

    def current_client
      @client_mutex.synchronize { @client }
    end

    def connected?
      @client_mutex.synchronize { @connected }
    end

    def current_client?(client)
      @client_mutex.synchronize { @running && @client.equal?(client) }
    end

    def active_run?(run_generation)
      @running && @run_generation.equal?(run_generation)
    end

    def bounded_payload(value)
      encoded = JSON.generate(value)
      return value if encoded.bytesize <= MAX_EVENT_PAYLOAD_BYTES
      { "truncated" => true, "bytes" => encoded.bytesize }
    rescue Exception
      { "truncated" => true, "bytes" => -1 }
    end

    def entity_payload(entity)
      {
        "persistentId" => safe_integer(entity, :persistent_id),
        "type" => safe_string(entity, :typename) || entity.class.name.to_s.split("::").last
      }.compact
    end

    def safe_string(object, method_name)
      return nil unless object.respond_to?(method_name)
      value = object.public_send(method_name)
      value.nil? ? nil : value.to_s
    rescue Exception
      nil
    end

    def safe_integer(object, method_name)
      return nil unless object.respond_to?(method_name)
      value = object.public_send(method_name)
      value.nil? ? nil : value.to_i
    rescue Exception
      nil
    end

    def log(message)
      puts "[DSH SketchUp] #{message}"
    end
  end

  class ModelObserver < Sketchup::ModelObserver
    def initialize(manager)
      super()
      @manager = manager
    end

    def onTransactionCommit(model)
      @manager.transaction("commit", model)
    end

    def onTransactionUndo(model)
      @manager.transaction("undo", model)
    end

    def onTransactionRedo(model)
      @manager.transaction("redo", model)
    end
  end

  class EntitiesObserver < Sketchup::EntitiesObserver
    def initialize(manager)
      super()
      @manager = manager
    end

    def onElementAdded(_entities, entity)
      @manager.entity_added(entity)
    end

    def onElementModified(_entities, entity)
      @manager.entity_modified(entity)
    end

    def onElementRemoved(_entities, entity_id)
      @manager.entity_removed(entity_id)
    end
  end

  class SelectionObserver < Sketchup::SelectionObserver
    def initialize(manager)
      super()
      @manager = manager
    end

    def onSelectionBulkChange(selection)
      @manager.selection_changed(selection)
    end

    def onSelectionAdded(selection, _entity)
      @manager.selection_changed(selection)
    end

    def onSelectionRemoved(selection, _entity)
      @manager.selection_changed(selection)
    end

    def onSelectionCleared(selection)
      @manager.selection_changed(selection)
    end
  end

  class AppObserver < Sketchup::AppObserver
    def initialize(manager)
      super()
      @manager = manager
    end

    def onNewModel(model)
      @manager.attach_model(model)
    end

    def onOpenModel(model)
      @manager.attach_model(model)
    end

    def onActivateModel(model)
      @manager.attach_model(model)
    end

    def onCloseModel(model)
      @manager.model_closed(model)
    end

    def onQuit
      @manager.stop
    end
  end

  @manager = Manager.new

  def self.manager
    @manager
  end

  def self.install
    menu = UI.menu("Extensions")
    menu.add_item("DSH SketchUp Bridge: Start/Stop") { manager.toggle }
    menu.add_item("DSH SketchUp Bridge: Open DSH Chat") { manager.open_chat }
     menu.add_item("DSH SketchUp Bridge: Status") { UI.messagebox(manager.status_text) }
    UI.start_timer(1.0, false) { manager.start }
  end
end

# SketchUp's file_loaded? guard prevents duplicate menu entries when the loader
# file is manually reloaded during plugin development.
unless file_loaded?(__FILE__)
  DSHSketchupBridge.install
  file_loaded(__FILE__)
end
