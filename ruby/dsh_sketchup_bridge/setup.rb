# frozen_string_literal: true

# Host setup is available from the root loader even if the bridge cannot connect.
# Network/disk work happens on a worker; SketchUp UI calls remain on its UI thread.
require 'net/http'
require 'uri'
require 'openssl'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'base64'
require 'thread'

module DSHSketchupBridge
  module HostSetup
    RELEASE_VERSION = '0.1.0-alpha.2'
    RELEASE_URL = "https://github.com/leolee9086/dsh-sketchup/releases/download/v#{RELEASE_VERSION}"
    MAX_DOWNLOAD = 1_048_576

    # GitHub redirects release assets to its CDN. Validate HTTPS on every hop,
    # and keep certificate verification enabled rather than accepting any peer.
    def self.download(url, destination, remaining = 8)
      raise 'Too many HTTPS redirects' if remaining < 0
      uri = URI.parse(url)
      raise 'Download refused: HTTPS is required' unless uri.is_a?(URI::HTTPS)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 20
      http.read_timeout = 60
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = "dsh-sketchup/#{RELEASE_VERSION}"
      redirect = nil
      http.start do |connection|
        connection.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection)
            raise 'Redirect has no Location header' unless response['location']
            redirect = URI.join(uri.to_s, response['location']).to_s
          elsif response.is_a?(Net::HTTPSuccess)
            raise 'Download exceeds size limit' if response['content-length'].to_i > MAX_DOWNLOAD
            size = 0
            File.open(destination, 'wb') do |file|
              response.read_body do |chunk|
                size += chunk.bytesize
                raise 'Download exceeds size limit' if size > MAX_DOWNLOAD
                file.write(chunk)
              end
            end
          else
            raise "Download failed: HTTP #{response.code}"
          end
        end
      end
      download(redirect, destination, remaining - 1) if redirect
      destination
    end

    def self.verify_bootstrap(script, sums)
      matches = File.readlines(sums).filter_map do |line|
        match = /\A([a-fA-F0-9]{64})\s+\*?bootstrap\.ps1\s*\z/.match(line)
        match && match[1].downcase
      end
      raise 'SHA256SUMS must contain exactly one bootstrap.ps1 entry' unless matches.length == 1
      raise 'Bootstrap SHA256 checksum mismatch' unless Digest::SHA256.file(script).hexdigest == matches.first
    end

    # Encode a script made only from single-quoted literals. No path, profile, or
    # executable value is interpolated as PowerShell code or passed through cmd.
    def self.ps_literal(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def self.launch_command(script, profile, dsh_home, dsh_command, install_dir)
      command = "& #{ps_literal(script)} -SkipRuby -Profile #{ps_literal(profile)}"
      command += " -DshHome #{ps_literal(dsh_home)} -DshCommand #{ps_literal(dsh_command)}"
      command += " -InstallDir #{ps_literal(install_dir)}" unless install_dir.empty?
      Base64.strict_encode64(command.encode('UTF-16LE'))
    end

    def self.start
      unless Sketchup.platform == :platform_win
        UI.messagebox('Automatic DSH Host setup is supported on Windows. On macOS, install DSH and pnpm first, then run install.sh from the release suite.')
        return
      end
      if @busy
        UI.messagebox('DSH Host installer download is already running.')
        return
      end
      home = ENV['DSH_HOME'] || File.join(Dir.home, '.dsh')
      values = UI.inputbox(
        ['DSH profile', 'DSH home directory', 'DSH executable (or dsh)', 'Private tool directory (blank = default)'],
        ['web', home, 'dsh', ''],
        'Install DSH Host — requires Node.js 22.13+ and npm'
      )
      return unless values
      profile, dsh_home, dsh_command, install_dir = values.map(&:to_s)
      unless /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(profile) && profile.downcase != 'desktop'
        UI.messagebox('Enter a valid DSH profile name.')
        return
      end
      if dsh_home.empty? || dsh_command.empty?
        UI.messagebox('DSH home and executable must not be empty.')
        return
      end
      @busy = true
      results = Queue.new
      # Polling delivers worker results through SketchUp's UI thread. The process
      # is detached after launch, so editing stays usable while npm/DSH install.
      timer = UI.start_timer(0.25, true) do
        unless results.empty?
          status, message = results.pop
          UI.stop_timer(timer)
          @busy = false
          UI.messagebox(message)
        end
      end
      Thread.new do
        directory = nil
        launched = false
        begin
          directory = Dir.mktmpdir('dsh-sketchup-host-')
          sums = download("#{RELEASE_URL}/SHA256SUMS", File.join(directory, 'SHA256SUMS'))
          script = download("#{RELEASE_URL}/bootstrap.ps1", File.join(directory, 'bootstrap.ps1'))
          verify_bootstrap(script, sums)
          powershell = File.join(ENV.fetch('SystemRoot', 'C:/Windows'), 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
          encoded = launch_command(script, profile, dsh_home, dsh_command, install_dir)
          pid = Process.spawn(powershell, '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded, new_pgroup: true)
          Process.detach(pid)
          launched = true
          # Keep the verified bootstrap until the external process has read it.
          # This small temp directory is intentionally retained for diagnostics.
          results << [:ok, "DSH Host installer opened in an external PowerShell window. SketchUp can remain open.\n\nAfter installation, start the DSH profile using the command printed there.\nVerified installer: #{script}"]
        rescue StandardError => error
          results << [:error, "DSH Host setup failed: #{error.message}"]
        ensure
          FileUtils.remove_entry(directory) if directory && !launched && File.directory?(directory)
        end
      end
    rescue StandardError => error
      @busy = false
      UI.messagebox("Cannot start DSH Host setup: #{error.message}")
    end

    def self.register_menu
      return if @menu_registered
      UI.menu('Extensions').add_item('Install DSH Host for SketchUp...') { start }
      @menu_registered = true
    end
  end
end
