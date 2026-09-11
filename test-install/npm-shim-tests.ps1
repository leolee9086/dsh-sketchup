# Exercise the actual installed npm.cmd without registry installs or live DSH.
param([string]$PowerShellCommand = 'pwsh')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$npm = Get-Command npm -ErrorAction Stop
$cmd = Join-Path (Split-Path -Parent $npm.Source) 'npm.cmd'
if (-not (Test-Path -LiteralPath $cmd)) { throw 'This regression check needs a Windows npm installation with sibling npm.cmd.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('real npm shim ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$root/source/lib" -Force | Out-Null
Set-Content "$root/source/package.json" '{"name":"@leolee9086/dsh-sketchup","version":"0.1.0-alpha.1","files":["lib"],"scripts":{"prepack":"exit 99","postpack":"exit 99"}}'
Set-Content "$root/source/lib/index.js" 'export default {}'
Set-Content "$root/mock dsh.ps1" '$args | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_REAL_NPM_LOG; exit 0'
Set-Content "$root/npmrc" ''
Set-Content "$root/globalnpmrc" ''
$env:TEST_REAL_NPM_LOG = "$root/dsh.json"
$env:npm_config_cache = "$root/npm cache"
$env:npm_config_userconfig = "$root/npmrc"
$env:npm_config_globalconfig = "$root/globalnpmrc"
$versionArguments = @('--version')
& $cmd @versionArguments
if ($LASTEXITCODE -ne 0) { throw 'Actual npm.cmd --version failed with splatted arguments.' }
# Check each production resolver without running its installer body.
foreach ($file in @('install.ps1', 'scripts/bootstrap.ps1')) {
  $tokens = $null; $errors = $null
  $tree = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file), [ref]$tokens, [ref]$errors)
  $function = $tree.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-NpmCommand' }, $true)
  if (-not $function) { throw "Missing npm resolver in $file" }
  . ([scriptblock]::Create($function.Extent.Text))
  if ((Resolve-NpmCommand) -ne $cmd) { throw "Wrong npm shim selected by $file" }
}
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/install.ps1" -SourceRoot "$root/source" -DshCommand "$root/mock dsh.ps1" -DshHome "$root/DSH home" -Profile test -SkipRuby
if ($LASTEXITCODE -ne 0) { throw 'Actual local npm pack via installer failed.' }
$arguments = Get-Content $env:TEST_REAL_NPM_LOG -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $arguments[-1])) { throw 'Actual npm tarball was not cached.' }
$bytes = [IO.File]::ReadAllBytes($arguments[-1])
if ($bytes.Length -lt 2 -or $bytes[0] -ne 31 -or $bytes[1] -ne 139) { throw 'Cached file is not an actual gzip tarball.' }
Set-Content "$root/source/package.json" '{"name":"@leolee9086/dsh-sketchup","version":"0.1.0-alpha.1","scripts":{"prepare":"exit 99"}}'
& $PowerShellCommand -NoProfile -ExecutionPolicy Bypass -File "$repo/install.ps1" -SourceRoot "$root/source" -DshCommand "$root/mock dsh.ps1" -DshHome "$root/rejected home" -Profile test -SkipRuby
if ($LASTEXITCODE -ne 1) { throw 'prepare lifecycle manifest was not rejected.' }
if (Test-Path "$root/rejected home") { throw 'prepare guard wrote installation files.' }
Write-Host "PASS: actual npm.cmd --version, local pack, prepare guard with $PowerShellCommand. Artifacts: $root"
