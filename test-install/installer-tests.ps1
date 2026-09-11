param([string]$PowerShellCommand = 'pwsh')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('installer test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$source = Join-Path $root 'suite source'
$plugins = Join-Path $root 'SketchUp Plugins'
$homeDir = Join-Path $root 'DSH home'
$mock = Join-Path $root 'mock dsh.ps1'
New-Item -ItemType Directory "$source/ruby/dsh_sketchup_bridge","$source/lib","$homeDir/profiles/test" -Force | Out-Null
Copy-Item "$repo/ruby/dsh_sketchup_bridge.rb" "$source/ruby/"
Copy-Item "$repo/ruby/dsh_sketchup_bridge/setup.rb","$repo/ruby/dsh_sketchup_bridge/main.rb" "$source/ruby/dsh_sketchup_bridge/"
Set-Content "$source/lib/index.js" '// prebuilt mock'
Set-Content "$source/package.json" '{"name":"@leolee9086/dsh-sketchup"}'
Set-Content "$homeDir/profiles/test/package.json" '{"original":true}'
Set-Content $mock '@{ args=@($args); home=$env:DSH_HOME } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:INSTALL_TEST_LOG; exit ([int]$env:INSTALL_TEST_EXIT)'
New-Item -ItemType Directory "$root/mock-bin" | Out-Null
Set-Content "$root/mock-bin/npm.ps1" 'if ($args[0] -ne "pack") { exit 92 }; Set-Content -LiteralPath (Join-Path $args[-1] "test.tgz") "mock packed source"; exit 0'
$env:PATH = "$root/mock-bin;" + $env:PATH
$env:INSTALL_TEST_LOG = Join-Path $root 'cli.json'
$env:INSTALL_TEST_EXIT = '0'
function Assert($value, $message) { if (-not $value) { throw $message } }
function Run-Install([string[]]$More) {
  & $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/install.ps1" -SourceRoot $source -PluginsDir $plugins -DshCommand $mock -DshHome $homeDir -Profile test @More
  return $LASTEXITCODE
}
$before = @(Get-ChildItem $root -Recurse -Force | ForEach-Object FullName)
$code = Run-Install @('-DryRun')
$after = @(Get-ChildItem $root -Recurse -Force | ForEach-Object FullName)
Assert ($code[-1] -eq 0) 'dry-run failed'
Assert (-not (Compare-Object $before $after)) 'dry-run created files'
Assert (-not (Test-Path $env:INSTALL_TEST_LOG)) 'dry-run invoked CLI'
$code = Run-Install @()
Assert ($code[-1] -eq 0) 'source install failed'
$invocation = Get-Content $env:INSTALL_TEST_LOG -Raw | ConvertFrom-Json
Assert (($invocation.args[0..4] -join '|') -eq 'plugin|--profile|test|add|--save-exact') 'wrong CLI flags'
Assert ($invocation.args[-1].StartsWith("$homeDir\packages\dsh-sketchup\")) 'source did not register durable cache'
Assert (Test-Path -LiteralPath $invocation.args[-1]) 'source cache missing after install'
Assert ($invocation.home -eq $homeDir) 'wrong DSH_HOME'
Assert (Test-Path "$plugins/dsh_sketchup_bridge/setup.rb") 'setup not installed'
Assert (@(Get-ChildItem "$homeDir/profiles/test/package.json.bak-*").Count -eq 1) 'profile input not backed up'
Set-Content "$plugins/dsh_sketchup_bridge/keep.txt" 'old extension'
Set-Content "$plugins/dsh_sketchup_bridge.rb" 'old root'
$code = Run-Install @('-SkipHost')
Assert ($code[-1] -eq 0) 'repeat Ruby install failed'
$backups = @(Get-ChildItem $plugins -Directory -Filter 'dsh_sketchup_bridge.bak-*')
Assert ($backups.Count -eq 1) 'Ruby directory backup missing'
Assert ((Get-Content (Join-Path $backups[0].FullName 'keep.txt')) -eq 'old extension') 'backup lost contents'
$code = Run-Install @('-SkipHost')
Assert (@(Get-ChildItem $plugins -Directory -Filter 'dsh_sketchup_bridge.bak-*').Count -eq 2) 'repeat install replaced existing backup'
$env:INSTALL_TEST_EXIT = '37'
$beforeRuby = (Get-FileHash "$plugins/dsh_sketchup_bridge.rb").Hash
$code = Run-Install @()
Assert ($code[-1] -eq 37) 'native error exit code not preserved'
Assert ((Get-FileHash "$plugins/dsh_sketchup_bridge.rb").Hash -eq $beforeRuby) 'failed Host installation modified Ruby'
$env:INSTALL_TEST_EXIT = '0'
# Force the second Ruby replacement to fail: both components must roll back.
Set-Content "$plugins/dsh_sketchup_bridge/rollback-sentinel.txt" 'preserve pair'
$rootLock = [IO.File]::Open("$plugins/dsh_sketchup_bridge.rb", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try { $code = Run-Install @('-SkipHost') } finally { $rootLock.Dispose() }
Assert ($code[-1] -eq 1) 'locked root unexpectedly replaced'
Assert ((Get-Content "$plugins/dsh_sketchup_bridge/rollback-sentinel.txt") -eq 'preserve pair') 'Ruby pair rollback lost original directory'
# Missing build output uses only mocked package tools and propagates build failure.
Set-Content "$root/mock-bin/pnpm.ps1" 'Add-Content -LiteralPath $env:INSTALL_BUILD_LOG ($args -join "|"); if ($env:INSTALL_BUILD_EXIT -ne "0") { exit ([int]$env:INSTALL_BUILD_EXIT) }; if ($args[0] -eq "run") { Set-Content "lib/index.js" "built by mock" }; exit 0'
$env:INSTALL_BUILD_LOG = Join-Path $root 'build.log'
$env:INSTALL_BUILD_EXIT = '29'
Remove-Item "$source/lib/index.js"
$beforeLog = (Get-FileHash $env:INSTALL_TEST_LOG).Hash
$code = Run-Install @('-SkipRuby')
Assert ($code[-1] -eq 29) 'source build error code lost'
Assert ((Get-FileHash $env:INSTALL_TEST_LOG).Hash -eq $beforeLog) 'failed build invoked DSH'
$env:INSTALL_BUILD_EXIT = '0'
$code = Run-Install @('-SkipRuby')
Assert ($code[-1] -eq 0) 'mock source build failed'
Assert ((Get-Content $env:INSTALL_BUILD_LOG -Raw).Contains('install|--frozen-lockfile|--ignore-scripts')) 'source install enabled dependency lifecycle scripts'
Assert (Test-Path "$source/lib/index.js") 'build output missing'
Set-Content "$source/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz" 'mock packed release'
$code = Run-Install @('-SkipRuby')
$invocation = Get-Content $env:INSTALL_TEST_LOG -Raw | ConvertFrom-Json
Assert ((Get-FileHash -LiteralPath $invocation.args[-1]).Hash -eq (Get-FileHash "$source/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz").Hash) 'release tarball not cached'
# Offline bootstrap exercises checksum and extraction using the same real installer and mock DSH.
Copy-Item "$repo/install.ps1" "$source/install.ps1"
$archive = Join-Path $root 'dsh-sketchup-0.1.0-alpha.1.zip'
Compress-Archive -Path "$source/*" -DestinationPath $archive
$sums = Join-Path $root 'SHA256SUMS'
Set-Content $sums (((Get-FileHash $archive).Hash.ToLower()) + '  dsh-sketchup-0.1.0-alpha.1.zip')
$before = @(Get-ChildItem $root -Recurse -Force | ForEach-Object FullName)
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/scripts/bootstrap.ps1" -DryRun -SuiteZip $archive -ChecksumFile $sums -DshHome $homeDir -DshCommand $mock -Profile test -SkipRuby
Assert ($LASTEXITCODE -eq 0) 'bootstrap dry run failed'
$after = @(Get-ChildItem $root -Recurse -Force | ForEach-Object FullName)
Assert (-not (Compare-Object $before $after)) 'bootstrap dry run wrote files'
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/scripts/bootstrap.ps1" -SuiteZip $archive -ChecksumFile $sums -DshHome $homeDir -DshCommand $mock -Profile test -SkipRuby
Assert ($LASTEXITCODE -eq 0) 'offline verified bootstrap failed'
$invocation = Get-Content $env:INSTALL_TEST_LOG -Raw | ConvertFrom-Json
Assert (Test-Path -LiteralPath $invocation.args[-1]) 'bootstrap registered temporary archive removed on cleanup'
Assert ($invocation.args[-1].StartsWith("$homeDir\packages\dsh-sketchup\")) 'bootstrap cache outside selected DSH home'
$env:INSTALL_TEST_EXIT = '43'
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/scripts/bootstrap.ps1" -SuiteZip $archive -ChecksumFile $sums -DshHome $homeDir -DshCommand $mock -Profile test -SkipRuby
Assert ($LASTEXITCODE -eq 43) 'bootstrap did not preserve inner native exit'
$env:INSTALL_TEST_EXIT = '0'
Set-Content $sums (('0' * 64) + '  dsh-sketchup-0.1.0-alpha.1.zip')
$logHash = (Get-FileHash $env:INSTALL_TEST_LOG).Hash
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/scripts/bootstrap.ps1" -SuiteZip $archive -ChecksumFile $sums -DshHome $homeDir -DshCommand $mock -Profile test -SkipRuby
Assert ($LASTEXITCODE -eq 1) 'invalid checksum accepted'
Assert ((Get-FileHash $env:INSTALL_TEST_LOG).Hash -eq $logHash) 'invalid checksum invoked DSH'
Write-Host "PASS: Windows installer mock suite. Artifacts: $root"
