# frozen_string_literal: true

# A deliberately small RFC 6455 client implemented with SketchUp's bundled
# Ruby standard library. SketchUp 2024 ships socket.rb, so no gem install or
# native extension is needed. The client only supports the text/control frames
# required by this local bridge and rejects oversized messages.
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

    BRIDGE_ORIGIN = "sketchup://dsh-bridge"

    def initialize(host:, port:, path:, timeout: 5)
      @host = host
      @port = port
      @path = path
      @timeout = timeout
      @socket = nil
      @write_mutex = Mutex.new
      @read_buffer = +"".b
      @fragment_opcode = nil
      @fragments = []
    end

    # Open TCP, complete the HTTP upgrade, and verify the server challenge.
    def connect
      @socket = Timeout.timeout(@timeout) { TCPSocket.new(@host, @port) }
      @socket.sync = true
      key = Base64.strict_encode64(SecureRandom.random_bytes(16))
      request = [
        "GET #{@path} HTTP/1.1",
        "Host: #{@host}:#{@port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "Origin: #{BRIDGE_ORIGIN}",
        "",
        ""
      ].join("\r\n")
      # SketchUp embeds Ruby in a GUI process. Flush explicitly after the
      # upgrade bytes so no Ruby IO buffering boundary can defer the handshake.
      @socket.write(request)
      @socket.flush

      headers = Timeout.timeout(@timeout) { read_http_headers }
      status = headers["__status__"].to_s
      raise "WebSocket upgrade rejected: #{status}" unless status.match?(/\AHTTP\/\d(?:\.\d)?\s+101(?:\s|\z)/)

      expected = Base64.strict_encode64(Digest::SHA1.digest(key + WEBSOCKET_GUID))
      actual = headers["sec-websocket-accept"]
      raise "WebSocket accept key mismatch" unless actual == expected
      self
    rescue Exception
      close
      raise
    end

    # Send one JSON object as a masked client text frame.
    def send_json(value)
      send_frame(0x1, JSON.generate(value))
    end

    # Read the next text JSON message. Ping/pong and close control frames are
    # handled internally, so callers only see application objects or nil.
    def read_json
      loop do
        frame = read_frame
        return nil if frame.nil?
        fin, opcode, payload = frame

        case opcode
        when 0x8 # close
          send_frame(0x8, payload) if open?
          return nil
        when 0x9 # ping
          send_frame(0xA, payload)
        when 0xA # pong
          next
        when 0x1 # text start
          if fin
            return JSON.parse(payload)
          else
            @fragment_opcode = opcode
            @fragments = [payload]
          end
        when 0x2 # binary start
          raise "binary WebSocket messages are not supported"
        when 0x0 # continuation
          raise "unexpected WebSocket continuation frame" if @fragment_opcode.nil?
          @fragments << payload
          if fin
            complete = @fragments.join
            opcode = @fragment_opcode
            @fragment_opcode = nil
            @fragments = []
            return JSON.parse(complete) if opcode == 0x1
          end
        else
          raise "unsupported WebSocket opcode #{opcode}"
        end
      end
    end

    def open?
      !@socket.nil? && !@socket.closed?
    end

    # Closing the socket interrupts a blocking reader on the worker thread.
    def close
      socket = @socket
      @socket = nil
      return if socket.nil?
      begin
        socket.close unless socket.closed?
      rescue IOError, SystemCallError
        # Teardown is best-effort; the reconnect loop owns the next socket.
      end
    end

    private

    def read_http_headers
      separator = nil
      until separator
        separator = @read_buffer.index("\r\n\r\n")
        break if separator
        @read_buffer << @socket.readpartial(1024).b
        raise "HTTP upgrade headers are too large" if @read_buffer.bytesize > 64 * 1024
      end
      raw = @read_buffer.byteslice(0, separator)
      consumed = separator + 4
      remaining = @read_buffer.byteslice(consumed, @read_buffer.bytesize - consumed)
      @read_buffer = remaining.nil? ? "".b : remaining
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
      fin = (first & 0x80) != 0
      opcode = first & 0x0F
      masked = (second & 0x80) != 0
      length_code = second & 0x7F
      raise "unsupported WebSocket opcode #{opcode}" unless [0x0, 0x1, 0x8, 0x9, 0xA].include?(opcode)
      raise "fragmented control frame" if opcode >= 0x8 && !fin
      raise "control frame payload is too large" if opcode >= 0x8 && length_code > 125

      length = case length_code
               when 126
                 read_exact(2).unpack1("n")
               when 127
                 high, low = read_exact(8).unpack("N2")
                 high * 4_294_967_296 + low
               else
                 length_code
               end
      raise "WebSocket frame exceeds #{MAX_FRAME_BYTES} bytes" if length > MAX_FRAME_BYTES
      raise "fragmented control frame" if opcode >= 0x8 && !fin

      mask = masked ? read_exact(4) : nil
      payload = read_exact(length)
      raise "unexpected end of WebSocket frame" if payload.nil?
      if masked && !mask.nil?
        bytes = payload.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }
        payload = bytes.pack("C*")
      end
      [fin, opcode, payload]
    end

    def read_exact(length)
      return "".b if length == 0
      result = +"".b
      while result.bytesize < length
        if @read_buffer.bytesize.positive?
          take = [length - result.bytesize, @read_buffer.bytesize].min
          result << @read_buffer.slice!(0, take)
          next
        end
        chunk = @socket.read(length - result.bytesize)
        return nil if chunk.nil? || chunk.empty?
        result << chunk.b
      end
      result
    end

    def send_frame(opcode, payload)
      data = payload.to_s.b
      raise "WebSocket payload exceeds #{MAX_FRAME_BYTES} bytes" if data.bytesize > MAX_FRAME_BYTES
      mask = SecureRandom.random_bytes(4)
      masked = data.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      length = data.bytesize
      header = [0x80 | opcode].pack("C")
      extension = if length < 126
                    [(0x80 | length)].pack("C")
                  elsif length <= 0xFFFF
                    [0x80 | 126].pack("C") + [length].pack("n")
                  else
                    high = length / 4_294_967_296
                    low = length % 4_294_967_296
                    [0x80 | 127].pack("C") + [high, low].pack("N2")
                  end
      @write_mutex.synchronize do
        raise "WebSocket is closed" unless open?
        @socket.write(header + extension + mask + masked)
      end
    end
  end
end
