# frozen_string_literal: true

# Deliberately NOT a sandbox. This opt-in evaluates trusted Ruby on SketchUp's
# UI thread, with the same process privileges as an installed extension. Scripts
# own their operations/transactions and may open/save models. Never use an async
# Timeout around native SketchUp calls. Queue expiry is handled by Manager.
require "json"

module DSHSketchupBridge
  module RubyExecution
    MAX_OUTPUT_BYTES = 64 * 1024 # each Ruby stream, not native file descriptors
    MAX_RESULT_BYTES = 128 * 1024
    MAX_STRING_BYTES = 16 * 1024
    MAX_RESULT_DEPTH = 12
    MAX_RESULT_NODES = 4096
    MAX_CONTAINER_ITEMS = 256

    # Slice BEFORE transcoding so a huge value cannot create another huge string.
    # Binary output often contains UTF-8 bytes; invalid sequences are replaced.
    def self.utf8_prefix(value, limit)
      prefix = value.byteslice(0, limit) || ""
      prefix = prefix.dup.force_encoding(Encoding::UTF_8) if prefix.encoding == Encoding::BINARY
      text = prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�").scrub
      truncated = value.bytesize > prefix.bytesize || text.bytesize > limit
      text = text.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub("") if text.bytesize > limit
      [text, truncated]
    rescue EncodingError
      text = (value.byteslice(0, limit) || "").dup.force_encoding(Encoding::UTF_8).scrub
      clipped = text.bytesize > limit || value.bytesize > limit
      [text.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub(""), clipped]
    end

    # Retains at most MAX_OUTPUT_BYTES while still reporting the write byte count.
    # Only $stdout/$stderr are redirected: STDOUT/STDERR constants, native output
    # and spawned processes are outside this capture (no descriptor reopening).
    class Output
      attr_accessor :sync
      attr_reader :bytes_written

      def initialize(limit = MAX_OUTPUT_BYTES)
        @limit = limit
        @buffer = String.new(encoding: Encoding::BINARY)
        @bytes_written = 0
        @closed = false
        @sync = true
      end

      def write(*values)
        raise IOError, "closed stream" if @closed
        count = 0
        values.each do |value|
          text = value.is_a?(String) ? value : value.to_s
          count += text.bytesize
          room = @limit - @buffer.bytesize
          @buffer << text.byteslice(0, room).b if room.positive?
        end
        @bytes_written += count
        count
      end

      def <<(value)
        write(value)
        self
      end

      def print(*values)
        values.each { |value| write(value.to_s) }
        write($\) unless $\.nil?
        nil
      end

      def puts(*values)
        values = [""] if values.empty?
        seen = {}
        emit = lambda do |value|
          if value.is_a?(Array)
            if seen[value.object_id]
              write("[...]\n")
            else
              seen[value.object_id] = true
              value.each { |item| emit.call(item) }
              seen.delete(value.object_id)
            end
          else
            text = value.nil? ? "" : value.to_s
            write(text)
            write("\n") unless text.end_with?("\n")
          end
        end
        values.each { |value| emit.call(value) }
        nil
      end

      def printf(format, *values)
        write(format % values)
        nil
      end

      def flush; self; end
      def close; @closed = true; nil; end
      def closed?; @closed; end
      def tty?; false; end
      alias isatty tty?
      def binmode; self; end
      def external_encoding; Encoding::UTF_8; end

      def snapshot
        text, clipped = RubyExecution.utf8_prefix(@buffer, @limit)
        { "text" => text, "bytes" => @bytes_written,
          "truncated" => clipped || @bytes_written > @buffer.bytesize }
      end
    end

    # Copy only known JSON value types. Never call an extension object's inspect,
    # to_json, to_h or as_json: those methods can be expensive or have side effects.
    # Node/item/string budgets bound work BEFORE JSON.generate; a final encoded
    # byte check also accounts for escaping, punctuation and replacement markers.
    class ResultValue
      attr_reader :truncated, :coerced

      def initialize
        @remaining = MAX_RESULT_BYTES
        @nodes = 0
        @truncated = false
        @coerced = false
        @ancestors = {}
      end

      def convert(value)
        result = visit(value, 0)
        if JSON.generate(result).bytesize > MAX_RESULT_BYTES
          @truncated = true
          result = "[Result exceeds JSON byte limit]"
        end
        result
      rescue Exception
        @coerced = true
        "[Result could not be serialized]"
      end

      private

      def text(value)
        safe, clipped = RubyExecution.utf8_prefix(value, [MAX_STRING_BYTES, @remaining].min)
        @remaining -= safe.bytesize
        @truncated ||= clipped
        safe
      end

      def visit(value, depth)
        @nodes += 1
        if depth > MAX_RESULT_DEPTH || @nodes > MAX_RESULT_NODES || @remaining <= 0
          @truncated = true
          return "[Result truncated]"
        end
        case value
        when NilClass, TrueClass, FalseClass
          value
        when Integer
          if value.bit_length > 4096
            @truncated = true
            "[Integer exceeds size limit]"
          else
            value
          end
        when Float
          if value.finite?
            value
          else
            @coerced = true
            value.to_s
          end
        when String
          text(value)
        when Symbol
          @coerced = true
          text(value.to_s)
        when Array, Hash
          if @ancestors[value.object_id]
            @coerced = true
            return "[Circular]"
          end
          @ancestors[value.object_id] = true
          begin
            output = value.is_a?(Array) ? [] : {}
            count = 0
            value.each do |*item|
              if count >= MAX_CONTAINER_ITEMS || @nodes >= MAX_RESULT_NODES || @remaining <= 0
                @truncated = true
                break
              end
              count += 1
              if value.is_a?(Array)
                output << visit(item[0], depth + 1)
              else
                key, entry = item.length == 1 ? item[0] : item
                unless key.is_a?(String) || key.is_a?(Symbol)
                  @coerced = true
                  next # non-string keys have no lossless JSON-object equivalent
                end
                @coerced = true if key.is_a?(Symbol)
                key = text(key.to_s)
                if output.key?(key)
                  @coerced = true
                  next # do not silently overwrite after coercion/truncation
                end
                output[key] = visit(entry, depth + 1)
              end
            end
            output
          ensure
            @ancestors.delete(value.object_id)
          end
        else
          @coerced = true
          "[Unsupported Ruby object]"
        end
      end
    end

    def self.error_details(error)
      name, = utf8_prefix(error.class.name.to_s, 256)
      message, = utf8_prefix(error.message.to_s, MAX_STRING_BYTES)
      trace = Array(error.backtrace).first(20).map { |line| utf8_prefix(line.to_s, 1024).first }
      result = { "class" => name, "message" => message, "backtrace" => trace }
      result["exitStatus"] = error.status if error.is_a?(SystemExit)
      result
    rescue Exception
      { "class" => "Exception", "message" => "Ruby script failed; error details unavailable", "backtrace" => [] }
    end

    def self.execute(code, filename, instance_id)
      stdout = Output.new
      stderr = Output.new
      previous_stdout, previous_stderr = $stdout, $stderr
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw_result = nil
      failure = nil
      begin
        $stdout, $stderr = stdout, stderr
        # TOPLEVEL_BINDING is console-like, not an isolation/security boundary.
        raw_result = eval(code, TOPLEVEL_BINDING.dup, filename, 1)
      rescue Exception => error # includes SyntaxError/SystemExit, never kills SU for those
        failure = error_details(error)
      ensure
        $stdout, $stderr = previous_stdout, previous_stderr
      end
      converter = ResultValue.new
      result = failure.nil? ? converter.convert(raw_result) : nil
      out = stdout.snapshot
      err = stderr.snapshot
      payload = {
        "instanceId" => instance_id, "processId" => Process.pid,
        "success" => failure.nil?, "result" => result,
        "stdout" => out["text"], "stderr" => err["text"],
        "stdoutBytes" => out["bytes"], "stderrBytes" => err["bytes"],
        "stdoutTruncated" => out["truncated"], "stderrTruncated" => err["truncated"],
        "resultTruncated" => converter.truncated, "resultCoerced" => converter.coerced,
        "filename" => filename, "transactionManagedByScript" => true,
        "durationMs" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
      }
      payload["error"] = failure unless failure.nil?
      payload
    end
  end
end
