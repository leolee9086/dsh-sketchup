param([Parameter(Mandatory=$true)][string]$ReleaseDirectory)
$ErrorActionPreference = 'Stop'
$ReleaseDirectory = [IO.Path]::GetFullPath($ReleaseDirectory)
$version='0.1.0-alpha.1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dsh-release-verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
  $lines=Get-Content (Join-Path $ReleaseDirectory 'SHA256SUMS')
  Assert ($lines.Count -eq 4) 'Expected four checksummed release artifacts'
  foreach($line in $lines) {
    Assert ($line -match '^([a-f0-9]{64})  ([^/\\]+)$') 'Malformed checksum entry'
    $expected=$Matches[1]; $file=$Matches[2]
    Assert ((Get-FileHash (Join-Path $ReleaseDirectory $file)).Hash.ToLowerInvariant() -eq $expected) "Checksum mismatch: $file"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $suite=Join-Path $temp 'suite'
  [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $ReleaseDirectory "dsh-sketchup-$version.zip"),$suite)
  $rbz=Join-Path $temp 'rbz'
  [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $ReleaseDirectory "dsh-sketchup-$version.rbz"),$rbz)
  foreach($name in @('dsh_sketchup_bridge.rb','dsh_sketchup_bridge/main.rb','dsh_sketchup_bridge/model_adapter.rb','dsh_sketchup_bridge/websocket_client.rb','dsh_sketchup_bridge/setup.rb')) {
    Assert ((Get-FileHash (Join-Path $rbz $name)).Hash -eq (Get-FileHash (Join-Path "$suite/ruby" $name)).Hash) "RBZ/suite mismatch: $name"
  }
  Assert (Test-Path "$rbz/dsh_sketchup_bridge/LICENSE") 'RBZ license missing'
  $tgz="leolee9086-dsh-sketchup-$version.tgz"
  Assert ((Get-FileHash "$suite/$tgz").Hash -eq (Get-FileHash "$ReleaseDirectory/$tgz").Hash) 'Suite Host archive differs'
  Assert ((Get-FileHash "$suite/scripts/bootstrap.ps1").Hash -eq (Get-FileHash "$ReleaseDirectory/bootstrap.ps1").Hash) 'Bootstrap artifact differs'
  $unpack=Join-Path $temp 'host'
  New-Item -ItemType Directory $unpack | Out-Null
  & tar -xf "$ReleaseDirectory/$tgz" -C $unpack
  Assert ($LASTEXITCODE -eq 0) 'Cannot unpack Host tarball'
  $manifest=Get-Content "$unpack/package/package.json" -Raw | ConvertFrom-Json
  Assert ($manifest.name -eq '@leolee9086/dsh-sketchup' -and $manifest.version -eq $version) 'Wrong package identity'
  foreach($name in @('lib/index.js','LICENSE','THIRD-PARTY/core-js-LICENSE','install.ps1','ruby/dsh_sketchup_bridge/setup.rb')) { Assert (Test-Path "$unpack/package/$name") "Missing package file: $name" }
  Assert (-not (Get-ChildItem $suite,$rbz,$unpack -Recurse -File | Where-Object {$_.Name -eq 'RESUME.local.md' -or $_.Extension -in @('.skp','.skb','.log')})) 'Personal/runtime file in release'
  $plugins=Join-Path $temp 'SketchUp Plugins'
  & pwsh -NoProfile -File "$suite/install.ps1" -SkipHost -PluginsDir $plugins
  Assert ($LASTEXITCODE -eq 0) 'Packaged Ruby installer failed'
  Assert ((Get-FileHash "$plugins/dsh_sketchup_bridge/setup.rb").Hash -eq (Get-FileHash "$rbz/dsh_sketchup_bridge/setup.rb").Hash) 'Installed Ruby differs'
  $mock=Join-Path $temp 'mock-dsh.ps1'
  Set-Content $mock 'if ($args[0] -ne "plugin" -or -not (Test-Path $args[-1])) {exit 91}; Set-Content -LiteralPath (Join-Path $env:DSH_HOME "registered.txt") $args[-1]; exit 0'
  $dshHome=Join-Path $temp 'DSH home'
  & pwsh -NoProfile -File "$suite/scripts/bootstrap.ps1" -SuiteZip "$ReleaseDirectory/dsh-sketchup-$version.zip" -ChecksumFile "$ReleaseDirectory/SHA256SUMS" -DshCommand $mock -DshHome $dshHome -SkipRuby
  Assert ($LASTEXITCODE -eq 0) 'Packaged offline bootstrap failed'
  $registered=Get-Content "$dshHome/registered.txt"
  Assert (Test-Path $registered) 'Bootstrap registered temporary package'
  Assert ((Get-FileHash $registered).Hash -eq (Get-FileHash "$ReleaseDirectory/$tgz").Hash) 'Cached Host differs from released package'
  Write-Host 'PASS: all release hashes, RBZ/suite parity, package identity/licenses, actual Ruby install and offline bootstrap durable-cache integration'
} finally { if(Test-Path $temp) {Remove-Item $temp -Recurse -Force} }
