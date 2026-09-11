# frozen_string_literal: true

# RFC 6455 text/control client using SketchUp's bundled Ruby standard library.
# The reader and writer own all blocking IO. UI callbacks only enqueue bounded
# messages, so a Host that stops reading cannot freeze SketchUp's UI thread.
require "base64"
require "digest/sha1"
require "json"
require "securerandom"
require "socket"
require "timeout"

module DSHSketchupBridge
  class WebSocketClient
    WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    MAX_FRAME_BYTES = 8 * 1024 * 1024
    MAX_MESSAGE_BYTES = MAX_FRAME_BYTES
    MAX_OUTBOUND_BYTES = 16 * 1024 * 1024
    MAX_OUTBOUND_FRAMES = 256
    BRIDGE_ORIGIN = "sketchup://dsh-bridge"

    def initialize(host:, port:, path:, timeout: 5, read_timeout: 90)
      @host, @port, @path = host, port, path
      @timeout, @read_timeout = timeout, read_timeout
      @socket = nil
      @outbound_mutex = Mutex.new
      @outbound_ready = ConditionVariable.new
      @outbound = []
      @outbound_bytes = 0
      @writer = nil
      @read_buffer = +"".b
      reset_fragments
    end

    # A client object represents exactly one connection; the manager creates a
    # new object on reconnect. The RFC challenge verifies framing, not identity.
    def connect
      raise "WebSocket client cannot be reused" unless @writer.nil? && @socket.nil?
      @socket = Timeout.timeout(@timeout) { TCPSocket.new(@host, @port) }
      @socket.sync = true
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      request = [
        "GET #{@path} HTTP/1.1", "Host: #{@host}:#{@port}",
        "Upgrade: websocket", "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}", "Sec-WebSocket-Version: 13",
        "Origin: #{BRIDGE_ORIGIN}", "", ""
      ].join("\r\n")
      write_all(@socket, request)
      headers = Timeout.timeout(@timeout) { read_http_headers }
      status = headers["__status__"].to_s
      raise "WebSocket upgrade rejected: #{status}" unless status.match?(/\AHTTP\/\d(?:\.\d)?\s+101(?:\s|\z)/)
      expected = Base64.strict_encode64(Digest::SHA1.digest(key + WEBSOCKET_GUID))
      raise "WebSocket accept key mismatch" unless headers["sec-websocket-accept"] == expected
      start_writer
      self
    rescue Exception
      close
      raise
    end

    # Serialization is bounded by the message limit. Masking and socket writes
    # happen on the writer thread. Queue exhaustion fails closed, never waits.
    def send_json(value)
      send_frame(0x1, JSON.generate(value))
    end

    def read_json
      @read_deadline = monotonic_time + @read_timeout
      loop do
        frame = read_frame
        return nil if frame.nil?
        fin, opcode, payload = frame
        case opcode
        when 0x8
          send_frame(0x8, payload) if open?
          return nil
        when 0x9
          send_frame(0xA, payload)
        when 0xA
          next
        when 0x1
          raise "new text frame during a fragmented message" unless @fragment_opcode.nil?
          return parse_text(payload) if fin
          @fragment_opcode = opcode
          @fragments = payload
        when 0x0
          raise "unexpected WebSocket continuation frame" if @fragment_opcode.nil?
          raise "WebSocket message exceeds #{MAX_MESSAGE_BYTES} bytes" if @fragments.bytesize + payload.bytesize > MAX_MESSAGE_BYTES
          @fragments << payload
          return parse_text(@fragments) if fin
        else
          raise "unsupported WebSocket opcode #{opcode}"
        end
      end
    ensure
      # One String also prevents unlimited empty fragments retaining objects.
      reset_fragments
      @read_deadline = nil
    end

    def open?
      socket = @socket
      !socket.nil? && !socket.closed?
    end

    # No join here: this method may run on the UI thread. Closing the socket
    # interrupts readers/writers; signalling the queue releases an idle writer.
    def close
      socket = @outbound_mutex.synchronize do
        previous = @socket
        @socket = nil
        @outbound.clear
        @outbound_bytes = 0
        @outbound_ready.broadcast
        previous
      end
      socket.close unless socket.nil? || socket.closed?
    rescue IOError, SystemCallError
      # Teardown is best-effort; the manager creates a fresh client next time.
    end

    private

    def reset_fragments
      @fragment_opcode = nil
      @fragments = +"".b
    end

    def parse_text(payload)
      text = payload.dup.force_encoding(Encoding::UTF_8)
      raise "WebSocket text is not valid UTF-8" unless text.valid_encoding?
      JSON.parse(text)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def read_http_headers
      separator = nil
      until separator
        separator = @read_buffer.index("\r\n\r\n")
        break if separator
        @read_buffer << @socket.readpartial(1024).b
        raise "HTTP upgrade headers are too large" if @read_buffer.bytesize > 64 * 1024
      end
      raw = @read_buffer.byteslice(0, separator)
      @read_buffer = @read_buffer.byteslice(separator + 4..-1) || +"".b
      lines = raw.split("\r\n")
      result = { "__status__" => lines.shift.to_s }
      lines.each do |line|
        key, value = line.split(":", 2)
        result[key.downcase] = value.to_s.strip unless key.nil?
      end
      result
    end

    def read_frame
      header = read_exact(2)
      return nil if header.nil?
      first, second = header.bytes
      raise "WebSocket reserved bits are not supported" unless (first & 0x70).zero?
      raise "server WebSocket frames must not be masked" unless (second & 0x80).zero?
      fin, opcode, length_code = (first & 0x80) != 0, first & 0x0F, second & 0x7F
      raise "unsupported WebSocket opcode #{opcode}" unless [0x0, 0x1, 0x8, 0x9, 0xA].include?(opcode)
      raise "fragmented control frame" if opcode >= 0x8 && !fin
      raise "control frame payload is too large" if opcode >= 0x8 && length_code > 125
      raise "unexpected WebSocket continuation frame" if opcode == 0 && @fragment_opcode.nil?
      raise "new text frame during a fragmented message" if opcode == 1 && !@fragment_opcode.nil?
      length = case length_code
               when 126
                 required_bytes(2).unpack1("n")
               when 127
                 high, low = required_bytes(8).unpack("N2")
                 raise "invalid WebSocket 64-bit length" unless (high & 0x80000000).zero?
                 high * 4_294_967_296 + low
               else
                 length_code
               end
      raise "WebSocket frame exceeds #{MAX_FRAME_BYTES} bytes" if length > MAX_FRAME_BYTES
      # Refuse oversized continuation payloads before reading/allocating them.
      if opcode == 0 && @fragments.bytesize + length > MAX_MESSAGE_BYTES
        raise "WebSocket message exceeds #{MAX_MESSAGE_BYTES} bytes"
      end
      [fin, opcode, required_bytes(length)]
    end

    def required_bytes(length)
      read_exact(length) || raise("unexpected end of WebSocket frame")
    end

    def read_exact(length)
      result = +"".b
      while result.bytesize < length
        unless @read_buffer.empty?
          result << @read_buffer.slice!(0, [length - result.bytesize, @read_buffer.bytesize].min)
          next
        end
        socket = @socket
        raise "WebSocket is closed" if socket.nil?
        deadline = @read_deadline || (monotonic_time + @read_timeout)
        wait_io(socket, false, deadline)
        chunk = socket.read_nonblock(length - result.bytesize, exception: false)
        next if chunk == :wait_readable
        if chunk.nil? || chunk.empty?
          raise "unexpected end of WebSocket frame" unless result.empty?
          return nil
        end
        result << chunk.b
      end
      result
    end

    def send_frame(opcode, payload)
      data = payload.to_s.b
      raise "WebSocket payload exceeds #{MAX_FRAME_BYTES} bytes" if data.bytesize > MAX_FRAME_BYTES
      raise "control frame payload is too large" if opcode >= 0x8 && data.bytesize > 125
      accepted = @outbound_mutex.synchronize do
        raise "WebSocket is closed" unless open?
        if @outbound.length >= MAX_OUTBOUND_FRAMES || @outbound_bytes + data.bytesize > MAX_OUTBOUND_BYTES
          false
        else
          @outbound << [opcode, data]
          @outbound_bytes += data.bytesize
          @outbound_ready.signal
          true
        end
      end
      unless accepted
        close
        raise "WebSocket outbound queue is full"
      end
      true
    end

    def start_writer
      socket = @socket
      @writer = Thread.new do
        begin
          loop do
            item = @outbound_mutex.synchronize do
              @outbound_ready.wait(@outbound_mutex) while @outbound.empty? && @socket.equal?(socket)
              if @socket.equal?(socket)
                next_item = @outbound.shift
                @outbound_bytes -= next_item[1].bytesize
                next_item
              end
            end
            break if item.nil?
            write_all(socket, encode_frame(*item))
          end
        rescue StandardError
          # Disconnect invalidates queued tools in Manager. A partial write
          # cannot be resumed on another connection and must never be replayed.
          close
        end
      end
    end

    def encode_frame(opcode, data)
      # Frame bytes are binary even when this helper receives a UTF-8 String.
      # Mutating a UTF-8 duplicate with mask bytes makes concatenation fail.
      data = data.b
      mask = SecureRandom.random_bytes(4)
      masked = data.dup
      data.bytesize.times { |index| masked.setbyte(index, data.getbyte(index) ^ mask.getbyte(index % 4)) }
      length = data.bytesize
      extension = if length < 126
                    [0x80 | length].pack("C")
                  elsif length <= 0xFFFF
                    [0x80 | 126, length].pack("Cn")
                  else
                    [0x80 | 127, length / 4_294_967_296, length % 4_294_967_296].pack("CN2")
                  end
      [0x80 | opcode].pack("C") + extension + mask + masked
    end

    def write_all(socket, data)
      deadline = monotonic_time + @timeout
      offset = 0
      while offset < data.bytesize
        wait_io(socket, true, deadline)
        written = socket.write_nonblock(data.byteslice(offset, [64 * 1024, data.bytesize - offset].min), exception: false)
        next if written == :wait_writable
        raise "WebSocket write made no progress" unless written.is_a?(Integer) && written > 0
        offset += written
      end
    end

    def wait_io(socket, writing, deadline)
      loop do
        raise "WebSocket is closed" unless @socket.equal?(socket) && !socket.closed?
        remaining = deadline - monotonic_time
        raise Timeout::Error, "WebSocket #{writing ? 'write' : 'read'} timed out" if remaining <= 0
        ready = IO.select(writing ? nil : [socket], writing ? [socket] : nil, nil, [remaining, 0.1].min)
        return unless ready.nil?
      end
    end
  end
end
