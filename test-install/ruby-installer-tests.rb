require 'tmpdir'
require 'json'
require 'base64'
require 'digest'
require_relative '../ruby/dsh_sketchup_bridge/setup'
def assert(value, message)
  raise message unless value
end
module UI
  def self.menu(name)
    raise 'wrong menu' unless name == 'Extensions'
    self
  end
  def self.add_item(name, &block)
    @items ||= []
    @items << [name, block]
  end
  def self.items = @items
end
DSHSketchupBridge::HostSetup.register_menu
DSHSketchupBridge::HostSetup.register_menu
assert(UI.items.length == 1, 'menu registered twice')
assert(UI.items[0][0] == 'Install DSH Host for SketchUp...', 'menu label wrong')
setup = DSHSketchupBridge::HostSetup
Dir.mktmpdir('ruby installer test ') do |dir|
  script = File.join(dir, "bootstrap's safe.ps1")
  sums = File.join(dir, 'SHA256SUMS')
  File.write(script, 'param([switch]$SkipRuby,[string]$Profile,[string]$DshHome,[string]$DshCommand,[string]$InstallDir); @($Profile,$DshHome,$DshCommand,$InstallDir) | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_RUBY_ARGS')
  digest = Digest::SHA256.file(script).hexdigest
  File.write(sums, "#{digest}  bootstrap.ps1\n")
  setup.verify_bootstrap(script, sums)
  File.write(sums, "#{'0' * 64}  bootstrap.ps1\n")
  begin
    setup.verify_bootstrap(script, sums)
    raise 'invalid checksum accepted'
  rescue RuntimeError => error
    raise unless error.message.include?('mismatch')
  end
  File.write(sums, "#{digest}  bootstrap.ps1\n#{digest}  bootstrap.ps1\n")
  begin
    setup.verify_bootstrap(script, sums)
    raise 'duplicate checksum accepted'
  rescue RuntimeError => error
    raise unless error.message.include?('exactly one')
  end
  values = ['test', "C:/home x'$([System.IO.File]::WriteAllText('BAD','bad'))", "dsh with ' quotes & chars.ps1", 'C:/private (tool)']
  encoded = setup.launch_command(script, *values)
  ENV['TEST_RUBY_ARGS'] = File.join(dir, 'args.json')
  success = system(ENV.fetch('PWSH_COMMAND', 'pwsh'), '-NoProfile', '-EncodedCommand', encoded)
  assert(success, 'encoded launcher failed')
  actual = JSON.parse(File.read(ENV['TEST_RUBY_ARGS'], encoding: 'bom|utf-8'))
  assert(actual == values, 'launcher altered/injected arguments')
  assert(!File.exist?('BAD'), 'PowerShell injection executed')
  begin
    setup.download('http://example.test/unsafe', File.join(dir, 'download'))
    raise 'HTTP URL accepted'
  rescue RuntimeError => error
    raise unless error.message.include?('HTTPS is required')
  end
  assert(!File.exist?(File.join(dir, 'download')), 'refused URL wrote a file')
end
puts 'PASS: Ruby menu idempotency, checksum match/mismatch/duplicates, literal encoded PowerShell arguments, HTTPS requirement'
