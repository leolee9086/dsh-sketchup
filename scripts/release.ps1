[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json
$version = $manifest.version
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('release/' + $version) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
# Refuse to mix a fresh release with old artifacts or replace an existing build.
if (Test-Path $OutputDirectory) { throw "Output directory already exists: $OutputDirectory" }
New-Item -ItemType Directory $OutputDirectory | Out-Null
$stage = Join-Path $OutputDirectory '.staging'
New-Item -ItemType Directory $stage | Out-Null
Push-Location $root
try {
  & pnpm run build
  if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
  # npm.ps1 reparses call-operator source incorrectly in some Node installers.
  # The Windows command shim forwards the argument vector without that rewrite.
  & npm.cmd pack --ignore-scripts --pack-destination $OutputDirectory
  if ($LASTEXITCODE -ne 0) { throw 'Host package creation failed' }
  $tgz = "leolee9086-dsh-sketchup-$version.tgz"
  if (-not (Test-Path (Join-Path $OutputDirectory $tgz))) { throw "Missing package $tgz" }
  $rbzRoot = Join-Path $stage 'rbz'
  New-Item -ItemType Directory $rbzRoot | Out-Null
  Copy-Item (Join-Path $root 'ruby/dsh_sketchup_bridge.rb') $rbzRoot
  Copy-Item (Join-Path $root 'ruby/dsh_sketchup_bridge') $rbzRoot -Recurse
  Copy-Item (Join-Path $root 'LICENSE') (Join-Path $rbzRoot 'dsh_sketchup_bridge/LICENSE')
  Copy-Item (Join-Path $root 'README.md') (Join-Path $rbzRoot 'dsh_sketchup_bridge/README.md')
  Compress-Archive -Path (Join-Path $rbzRoot '*') -DestinationPath (Join-Path $OutputDirectory "dsh-sketchup-$version.rbz.zip")
  Move-Item (Join-Path $OutputDirectory "dsh-sketchup-$version.rbz.zip") (Join-Path $OutputDirectory "dsh-sketchup-$version.rbz")
  $suite = Join-Path $stage 'suite'
  New-Item -ItemType Directory $suite | Out-Null
  foreach ($item in @('install.ps1','install.sh','ruby','scripts','docs','THIRD-PARTY','README.md','LICENSE')) {
    Copy-Item (Join-Path $root $item) $suite -Recurse
  }
  Copy-Item (Join-Path $OutputDirectory $tgz) $suite
  Compress-Archive -Path (Join-Path $suite '*') -DestinationPath (Join-Path $OutputDirectory "dsh-sketchup-$version.zip")
  Copy-Item (Join-Path $root 'scripts/bootstrap.ps1') (Join-Path $OutputDirectory 'bootstrap.ps1')
  $hashes = Get-ChildItem $OutputDirectory -File | Sort-Object Name | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
  }
  [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS'), $hashes, [Text.UTF8Encoding]::new($false))
  Write-Host "Release artifacts: $OutputDirectory"
} finally {
  Pop-Location
  # Only this script's fresh staging directory is disposable.
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
}
