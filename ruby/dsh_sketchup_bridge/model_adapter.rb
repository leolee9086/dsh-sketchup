# frozen_string_literal: true

# SketchUp-facing operations. Every public method in this class is called from
# the SketchUp UI thread by main.rb. The WebSocket reader never touches this
# object directly, because most SketchUp Ruby API calls are not thread-safe.
require "fileutils"
require "json"

module DSHSketchupBridge
  class ModelAdapter
    DEFAULT_MAX_ENTITIES = 100
    DEFAULT_MAX_RESULTS = 50
    DEFAULT_HISTORY_LIMIT = 100
    MAX_ENTITIES = 2_000
    MAX_RESULTS = 500
    MAX_SELECTION = 500
    MAX_NESTED_DEPTH = 32
    MAX_CODE_BYTES = 1_000_000

    def initialize(manager)
      @manager = manager
    end

    # Dispatch one allow-listed tool name. Unknown names fail closed.
    def dispatch(name, args)
      case name
      when "sketchup_snapshot"
        snapshot(args)
      when "sketchup_selection"
        selection(args)
      when "sketchup_history"
        history(args)
      when "sketchup_query"
        query(args)
      when "sketchup_execute"
        execute(args)
      when "sketchup_write_plugin"
        write_plugin(args)
      when "sketchup_reload_plugin"
        reload_plugin(args)
      else
        raise ArgumentError, "unsupported SketchUp tool: #{name}"
      end
    end

    def snapshot(args)
      model = active_model!
      max_entities = bounded_integer(args["maxEntities"], DEFAULT_MAX_ENTITIES, 1, MAX_ENTITIES)
      include_geometry = args["includeGeometry"] != false
      include_hidden = args["includeHidden"] == true
      entities = []
      model.entities.each do |entity|
        next unless entity_valid?(entity)
        next if !include_hidden && hidden_entity?(entity)
        entities << entity_summary(entity, [], include_geometry)
        break if entities.length >= max_entities
      end

      selected, selection_truncated = selection_payload(model, true, MAX_SELECTION)
      payload = {
        "model" => model_summary(model),
        "selection" => selected,
        "selectionTruncated" => selection_truncated,
        "entities" => entities,
        "truncated" => model.entities.length > entities.length
      }
      text_result(payload)
    end

    def selection(args)
      model = active_model!
      include_details = args["includeDetails"] != false
      selected, selection_truncated = selection_payload(model, include_details, MAX_SELECTION)
      text_result({
        "model" => model_summary(model),
        "selection" => selected,
        "selectionTruncated" => selection_truncated,
        "activePath" => active_path_payload(model)
      })
    end

    def history(args)
      limit = bounded_integer(args["limit"], DEFAULT_HISTORY_LIMIT, 1, @manager.max_history_events)
      clear = args["clear"] == true
      value = @manager.history(limit)
      @manager.clear_history if clear
      text_result({ "events" => value, "count" => value.length, "cleared" => clear })
    end

    def query(args)
      model = active_model!
      max_results = bounded_integer(args["maxResults"], DEFAULT_MAX_RESULTS, 1, MAX_RESULTS)
      include_nested = args["includeNested"] == true
      persistent_id = integer_or_nil(args["persistentId"])
      requested_type = non_empty_string_or_nil(args["type"])
      requested_name = non_empty_string_or_nil(args["name"])
      raise ArgumentError, "sketchup_query needs persistentId, type, or name" if persistent_id.nil? && requested_type.nil? && requested_name.nil?

      matches = []
      walk_entities(model.entities, [], include_nested, {}) do |entity, path|
        next unless persistent_id.nil? || entity_persistent_id(entity) == persistent_id
        next unless requested_type.nil? || entity_type(entity).casecmp?(requested_type)
        next unless requested_name.nil? || entity_name(entity) == requested_name
        matches << entity_summary(entity, path, true)
        matches.length < max_results ? nil : :stop
      end
      text_result({ "matches" => matches, "count" => matches.length, "truncated" => matches.length >= max_results })
    end

    def execute(args)
      model = active_model!
      operation = non_empty_string_or_nil(args["operation"])
      raise ArgumentError, "sketchup_execute requires operation" if operation.nil?

      result = @manager.with_operation(operation) do
        transactional(model, "DSH: #{operation}") do
          case operation
          when "add_box"
            add_box(model, args)
          when "add_cylinder"
            add_cylinder(model, args)
          when "erase_selection"
            erase_selection(model)
          when "erase_entities"
            erase_entities(model, args)
          when "select_entities"
            select_entities(model, args)
          when "set_active_layer"
            set_active_layer(model, args)
          when "save_model"
            save_model(model)
          else
            raise ArgumentError, "unsupported structured operation: #{operation}"
          end
        end
      end
      @manager.record_event("command.executed", result)
      text_result(result)
    end

    private

    def active_model!
      model = Sketchup.active_model
      raise "SketchUp has no active model" if model.nil?
      model
    end

    def transactional(model, label)
      model.start_operation(label, true)
      begin
        value = yield
        model.commit_operation
        value
      rescue Exception
        begin
          model.abort_operation
        rescue Exception
          # Preserve the original failure; abort is only cleanup.
        end
        raise
      end
    end

    # Build each primitive inside its own group. SketchUp merges raw geometry
    # placed in the same Entities collection; creating a cylinder on a box's
    # coplanar top face can otherwise mutate that face while add_circle/add_face
    # are still resolving and destabilize the native geometry kernel.
    def primitive_group(model, name)
      group = active_entities(model).add_group
      group.name = name
      active_layer = safe_value(model, :active_layer) || safe_value(model, :active_tag)
      group.layer = active_layer if !active_layer.nil? && group.respond_to?(:layer=)
      group
    end

    def add_box(model, args)
      origin = point(args["origin"], "origin", [0.0, 0.0, 0.0])
      size = vector(args["size"], "size", [100.0, 100.0, 100.0])
      raise ArgumentError, "box dimensions must be positive" unless size.all? { |value| value > 0 }
      x, y, z = origin
      dx, dy, dz = size
      points = [
        [x, y, z],
        [x + dx, y, z],
        [x + dx, y + dy, z],
        [x, y + dy, z]
      ]
      group = primitive_group(model, "DSH Box")
      face = group.entities.add_face(points)
      raise "SketchUp could not create the box base face" if face.nil?
      face.pushpull(dz)
      {
        "operation" => "add_box",
        "createdPersistentIds" => [entity_persistent_id(group)].compact,
        "origin" => origin,
        "size" => size
      }
    end

    def add_cylinder(model, args)
      center = point(args["origin"], "origin", [0.0, 0.0, 0.0])
      radius = finite_number(args["radius"], "radius", 50.0)
      height = finite_number(args["height"], "height", 100.0)
      segments = bounded_integer(args["segments"], 24, 3, 256)
      raise ArgumentError, "cylinder radius and height must be positive" if radius <= 0 || height <= 0
      group = primitive_group(model, "DSH Cylinder")
      edges = group.entities.add_circle(Geom::Point3d.new(center), Geom::Vector3d.new(0, 0, 1), radius, segments)
      raise "SketchUp could not create the cylinder circle" if edges.nil? || edges.empty?
      face = group.entities.add_face(edges)
      raise "SketchUp could not create the cylinder face" if face.nil?
      face.pushpull(height)
      {
        "operation" => "add_cylinder",
        "createdPersistentIds" => [entity_persistent_id(group)].compact,
        "origin" => center,
        "radius" => radius,
        "height" => height,
        "segments" => segments
      }
    end

    def erase_selection(model)
      ids = model.selection.to_a.filter_map { |entity| entity_persistent_id(entity) }
      model.selection.to_a.each { |entity| entity.erase! if entity_valid?(entity) }
      model.selection.clear
      { "operation" => "erase_selection", "erasedPersistentIds" => ids }
    end

    def erase_entities(model, args)
      ids = integer_array(args["persistentIds"], "persistentIds")
      found = find_by_ids(model, ids, args["includeNested"] == true)
      found.each { |entity| entity.erase! if entity_valid?(entity) }
      { "operation" => "erase_entities", "requested" => ids, "erased" => found.filter_map { |entity| entity_persistent_id(entity) } }
    end

    def select_entities(model, args)
      ids = integer_array(args["persistentIds"], "persistentIds")
      found = find_by_ids(model, ids, args["includeNested"] == true)
      model.selection.clear
      found.each { |entity| model.selection.add(entity) if entity_valid?(entity) }
      { "operation" => "select_entities", "requested" => ids, "selected" => found.filter_map { |entity| entity_persistent_id(entity) } }
    end

    def set_active_layer(model, args)
      name = non_empty_string_or_nil(args["layerName"])
      raise ArgumentError, "layerName must be a non-empty string" if name.nil?
      layer = model.layers.add(name)
      if model.respond_to?(:active_layer=)
        model.active_layer = layer
      elsif model.respond_to?(:active_tag=)
        model.active_tag = layer
      else
        raise "this SketchUp version does not expose an active layer setter"
      end
      { "operation" => "set_active_layer", "layerName" => layer.name }
    end

    def save_model(model)
      raise "save_model requires the current model to have a file path" if model.path.to_s.empty?
      saved = model.save
      raise "SketchUp reported that the model could not be saved" unless saved
      { "operation" => "save_model", "path" => model.path.to_s, "saved" => true }
    end

    def write_plugin(args)
      raise ArgumentError, "confirm=true is required for plugin writes" unless args["confirm"] == true
      require_plugin_gate!(false)
      plugin_id = safe_plugin_id(args["pluginId"])
      entry_file = args["entryFile"].to_s
      code = args["code"]
      raise ArgumentError, "code must be a string" unless code.is_a?(String)
      raise ArgumentError, "plugin code is too large" if code.bytesize > MAX_CODE_BYTES
      path = safe_plugin_path(plugin_id, entry_file)
      syntax_check(code, path)
      FileUtils.mkdir_p(File.dirname(path))
      backup = backup_file(path)
      temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.open(temporary, "wb") { |file| file.write(code) }
      FileUtils.mv(temporary, path, force: true)

      loaded = false
      if args["load"] == true
        require_plugin_gate!(true)
        Kernel.load(path)
        loaded = true
      end
      @manager.record_event("plugin.written", { "pluginId" => plugin_id, "entryFile" => entry_file, "loaded" => loaded })
      {
        "operation" => "write_plugin",
        "pluginId" => plugin_id,
        "entryFile" => entry_file,
        "path" => path,
        "backup" => backup,
        "bytes" => code.bytesize,
        "loaded" => loaded
      }
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def reload_plugin(args)
      raise ArgumentError, "confirm=true is required for plugin reloads" unless args["confirm"] == true
      require_plugin_gate!(true)
      plugin_id = safe_plugin_id(args["pluginId"])
      entry_file = args["entryFile"].to_s
      path = safe_plugin_path(plugin_id, entry_file)
      raise "plugin file does not exist: #{entry_file}" unless File.file?(path)
      syntax_check(File.read(path, mode: "rb"), path)
      Kernel.load(path)
      @manager.record_event("plugin.reloaded", { "pluginId" => plugin_id, "entryFile" => entry_file })
      { "operation" => "reload_plugin", "pluginId" => plugin_id, "entryFile" => entry_file, "path" => path, "loaded" => true }
    end

    def require_plugin_gate!(load_code)
      unless @manager.plugin_write_enabled
        raise DSHSketchupBridge::PermissionError, "plugin writing is disabled by the DSH Host configuration"
      end
      return unless load_code
      unless @manager.plugin_load_enabled
        raise DSHSketchupBridge::PermissionError, "plugin loading is disabled by the DSH Host configuration"
      end
    end

    def safe_plugin_id(value)
      id = non_empty_string_or_nil(value)
      raise ArgumentError, "pluginId must be 1-64 ASCII letters, numbers, underscore, or hyphen" if id.nil? || id.length > 64 || id !~ /\A[A-Za-z0-9_-]+\z/
      id
    end

    def safe_plugin_path(plugin_id, entry_file)
      relative = entry_file.to_s.tr("\\", "/")
      parts = relative.split("/")
      raise ArgumentError, "entryFile must be a relative .rb path" if relative.empty? || !relative.end_with?(".rb") || parts.any? { |part| part.empty? || part == "." || part == ".." || part.include?("\0") }
      raise ArgumentError, "entryFile must stay below Plugins/#{plugin_id}" unless parts.first == plugin_id
      # Resolve from this installed extension instead of relying on
      # find_support_file("Plugins"), which has varied across SketchUp releases.
      root = File.expand_path(File.join(__dir__, ".."))
      raise "SketchUp Plugins directory could not be located" unless File.directory?(root)
      path = File.expand_path(File.join(root, *parts))
      prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      raise ArgumentError, "entryFile escapes the Plugins directory" unless path == root || path.downcase.start_with?(prefix.downcase)
      path
    end

    def backup_file(path)
      return nil unless File.file?(path)
      backup = "#{path}.bak-#{Time.now.strftime("%Y%m%d-%H%M%S-%L")}"
      suffix = 1
      while File.exist?(backup)
        backup = "#{path}.bak-#{Time.now.strftime("%Y%m%d-%H%M%S-%L")}-#{suffix}"
        suffix += 1
      end
      FileUtils.cp(path, backup)
      backup
    end

    def syntax_check(code, path)
      if defined?(RubyVM) && RubyVM.const_defined?(:InstructionSequence)
        RubyVM::InstructionSequence.compile(code, path)
      end
    rescue SyntaxError => error
      raise ArgumentError, "Ruby syntax error in #{path}: #{error.message}"
    end

    def active_entities(model)
      model.respond_to?(:active_entities) ? model.active_entities : model.entities
    end

    def find_by_ids(model, ids, include_nested)
      found = []
      walk_entities(model.entities, [], include_nested, {}) do |entity, _path|
        found << entity if ids.include?(entity_persistent_id(entity))
        found.length < ids.length ? nil : :stop
      end
      found
    end

    def walk_entities(entities, path, include_nested, visited, depth = 0, &block)
      return nil if depth > MAX_NESTED_DEPTH
      entities.each do |entity|
        next unless entity_valid?(entity)
        current_path = path + [entity_persistent_id(entity)].compact
        return :stop if yield(entity, current_path) == :stop
        next unless include_nested && depth < MAX_NESTED_DEPTH

        child_entities = if entity.is_a?(Sketchup::Group)
                           entity.entities
                         elsif entity.is_a?(Sketchup::ComponentInstance)
                           entity.definition.entities
                         end
        next if child_entities.nil?
        key = if entity.is_a?(Sketchup::ComponentInstance)
                safe_value(entity.definition, :persistent_id) || entity.definition.object_id
              else
                entity.object_id
              end
        next if visited[key]
        visited[key] = true
        return :stop if walk_entities(child_entities, current_path, true, visited, depth + 1, &block) == :stop
      end
      nil
    end

    def model_summary(model)
      {
        "path" => safe_value(model, :path).to_s,
        "title" => safe_value(model, :title).to_s,
        "guid" => safe_value(model, :guid).to_s,
        "activeLayer" => begin
          layer = safe_value(model, :active_layer) || safe_value(model, :active_tag)
          layer.nil? ? nil : safe_value(layer, :name).to_s
        end,
        "entityCount" => safe_value(model.entities, :length).to_i
      }
    end

    def selection_payload(model, include_details, max_items)
      selected = []
      model.selection.each do |entity|
        selected << if include_details
                      entity_summary(entity, [], true)
                    else
                      { "persistentId" => entity_persistent_id(entity), "type" => entity_type(entity) }
                    end
        break if selected.length >= max_items
      end
      [selected, model.selection.length > selected.length]
    end

    def active_path_payload(model)
      path = safe_value(model, :active_path)
      return [] unless path.respond_to?(:to_a)
      path.to_a.filter_map { |entity| entity_persistent_id(entity) }
    end

    def entity_summary(entity, path, include_geometry)
      result = {
        "persistentId" => entity_persistent_id(entity),
        "type" => entity_type(entity),
        "path" => path,
        "name" => entity_name(entity),
        "hidden" => hidden_entity?(entity),
        "visible" => safe_value(entity, :visible?).nil? ? nil : safe_value(entity, :visible?),
        "layer" => begin
          layer = safe_value(entity, :layer) || safe_value(entity, :tag)
          layer.nil? ? nil : safe_value(layer, :name).to_s
        end
      }
      if include_geometry
        bounds = safe_value(entity, :bounds)
        result["bounds"] = bounds_payload(bounds) unless bounds.nil?
        if entity.is_a?(Sketchup::Face)
          result["area"] = safe_value(entity, :area).to_f
          result["vertexCount"] = safe_value(entity, :vertices).to_a.length
        elsif entity.is_a?(Sketchup::Edge)
          result["length"] = safe_value(entity, :length).to_f
        elsif entity.is_a?(Sketchup::Group)
          result["childCount"] = entity.entities.length
        elsif entity.is_a?(Sketchup::ComponentInstance)
          result["definition"] = safe_value(entity.definition, :name).to_s
          result["childCount"] = entity.definition.entities.length
        end
      end
      result.delete_if { |_key, value| value.nil? }
      result
    end

    def bounds_payload(bounds)
      {
        "min" => point_array(bounds.min),
        "max" => point_array(bounds.max),
        "width" => bounds.width.to_f,
        "height" => bounds.height.to_f,
        "depth" => bounds.depth.to_f
      }
    rescue Exception
      nil
    end

    def entity_valid?(entity)
      entity.respond_to?(:valid?) ? entity.valid? : true
    rescue Exception
      false
    end

    def hidden_entity?(entity)
      value = safe_value(entity, :hidden?)
      value.nil? ? false : value
    end

    def entity_persistent_id(entity)
      value = safe_value(entity, :persistent_id)
      value.nil? ? nil : value.to_i
    end

    def entity_type(entity)
      value = safe_value(entity, :typename)
      value.nil? || value.to_s.empty? ? entity.class.name.to_s.split("::").last : value.to_s
    end

    def entity_name(entity)
      value = safe_value(entity, :name)
      value.nil? ? nil : value.to_s.empty? ? nil : value.to_s
    end

    def safe_value(object, method_name)
      return nil unless object.respond_to?(method_name)
      object.public_send(method_name)
    rescue Exception
      nil
    end

    def text_result(value)
      { "text" => JSON.pretty_generate(value) }
    end

    def point(value, name, default)
      array = value.nil? ? default : value
      vector(array, name, default)
    end

    def vector(value, name, default)
      array = value.nil? ? default : value
      unless array.is_a?(Array) && array.length == 3 && array.all? { |item| item.is_a?(Numeric) && item.finite? }
        raise ArgumentError, "#{name} must be an array of three finite numbers"
      end
      array.map(&:to_f)
    end

    def point_array(value)
      value.to_a.map(&:to_f)
    end

    def finite_number(value, name, default)
      number = value.nil? ? default : value
      raise ArgumentError, "#{name} must be a finite number" unless number.is_a?(Numeric) && number.finite?
      number.to_f
    end

    def bounded_integer(value, default, minimum, maximum)
      number = value.nil? ? default : value
      raise ArgumentError, "value must be an integer" unless number.is_a?(Numeric) && number.to_i == number
      [[number.to_i, minimum].max, maximum].min
    end

    def integer_or_nil(value)
      return nil if value.nil?
      raise ArgumentError, "persistentId must be an integer" unless value.is_a?(Numeric) && value.to_i == value
      value.to_i
    end

    def integer_array(value, name)
      raise ArgumentError, "#{name} must be a non-empty integer array" unless value.is_a?(Array) && !value.empty?
      value.map do |item|
        raise ArgumentError, "#{name} must contain integers" unless item.is_a?(Numeric) && item.to_i == item
        item.to_i
      end.uniq
    end

    def non_empty_string_or_nil(value)
      return nil unless value.is_a?(String)
      value.strip.empty? ? nil : value.strip
    end
  end

  class PermissionError < StandardError
  end
end
