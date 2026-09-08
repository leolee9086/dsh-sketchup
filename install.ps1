$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$plugins = if ($env:SKETCHUP_PLUGINS_DIR) { $env:SKETCHUP_PLUGINS_DIR } else { Join-Path $env:APPDATA 'SketchUp\SketchUp 2024\SketchUp\Plugins' }
if (-not (Test-Path $plugins)) { throw "SketchUp Plugins directory not found: $plugins" }
$targetDir = Join-Path $plugins 'dsh_sketchup_bridge'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($source in @('dsh_sketchup_bridge.rb')) {
  $target = Join-Path $plugins $source
  if (Test-Path $target) { Copy-Item $target "$target.bak-$stamp" }
  Copy-Item (Join-Path $root "ruby\$source") $target -Force
}
if (Test-Path $targetDir) { Rename-Item $targetDir "$targetDir.bak-$stamp" }
Copy-Item (Join-Path $root 'ruby\dsh_sketchup_bridge') $targetDir -Recurse
$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dsh) { Write-Warning 'dsh was not found; Ruby extension installed, Host registration must be done manually.'; exit 0 }
& dsh plugin --profile web add -w '@yuxianglin/dsh-bridge-sketchup@link:'$root
Write-Host "Installed SketchUp Ruby extension and linked Host package. Restart DSH and SketchUp."