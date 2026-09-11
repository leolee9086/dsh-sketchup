# Missing-tool branch of bootstrap: all commands are mocked and PATH is isolated.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$engine = (Get-Command pwsh).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('private tool test ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory "$root/bin","$root/suite" -Force | Out-Null
Copy-Item "$repo/install.ps1" "$root/suite/"
Set-Content "$root/suite/leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz" 'mock release'
$zip = Join-Path $root 'dsh-sketchup-0.1.0-alpha.1.zip'
Compress-Archive -Path "$root/suite/*" -DestinationPath $zip
$sums = Join-Path $root 'SHA256SUMS'
Set-Content $sums (((Get-FileHash $zip).Hash.ToLower()) + '  dsh-sketchup-0.1.0-alpha.1.zip')
Set-Content "$root/bin/node.ps1" 'Write-Output $env:TEST_NODE_VERSION; exit 0'
Set-Content "$root/mock-dsh.ps1" '@{ args=@($args); home=$env:DSH_HOME } | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_DSH_LOG; exit 0'
Set-Content "$root/bin/npm.ps1" @'
$args | ConvertTo-Json | Set-Content -LiteralPath $env:TEST_NPM_LOG
if ($env:TEST_NPM_EXIT -ne '0') { exit ([int]$env:TEST_NPM_EXIT) }
$prefix = $args[[array]::IndexOf($args, '--prefix') + 1]
New-Item -ItemType Directory (Join-Path $prefix 'node_modules/.bin') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $prefix 'node_modules/.bin/dsh.cmd') '@echo off
"%TEST_ENGINE%" -NoProfile -File "%TEST_DSH_SCRIPT%" %*
exit /b %ERRORLEVEL%'
Set-Content -LiteralPath (Join-Path $prefix 'node_modules/.bin/pnpm.cmd') '@exit /b 0'
exit 0
'@
$env:TEST_ENGINE = $engine
$env:TEST_DSH_SCRIPT = "$root/mock-dsh.ps1"
$env:TEST_DSH_LOG = "$root/dsh.json"
$env:TEST_NPM_LOG = "$root/npm.json"
$env:TEST_NPM_EXIT = '0'
$env:TEST_NODE_VERSION = 'v22.13.0'
$originalPath = $env:PATH
function Assert($value, $message) { if (-not $value) { throw $message } }
try {
  $env:PATH = "$root/bin"
  & $engine -NoProfile -File "$repo/scripts/bootstrap.ps1" -SuiteZip $zip -ChecksumFile $sums -DshHome "$root/home" -InstallDir "$root/private tools" -Profile test -SkipRuby
  Assert ($LASTEXITCODE -eq 0) 'private bootstrap failed'
  $npmArgs = Get-Content $env:TEST_NPM_LOG -Raw | ConvertFrom-Json
  Assert ($npmArgs -contains '@deepseek-ai/dsh@0.1.5-rc.2') 'missing pinned DSH'
  Assert ($npmArgs -contains 'pnpm@11.7.0') 'missing pinned pnpm'
  Assert (-not ($npmArgs -contains '-g')) 'global npm installation attempted'
  $dshArgs = Get-Content $env:TEST_DSH_LOG -Raw | ConvertFrom-Json
  Assert (Test-Path -LiteralPath $dshArgs.args[-1]) 'private bootstrap left ephemeral dependency'
  $before = (Get-FileHash $env:TEST_NPM_LOG).Hash
  & $engine -NoProfile -File "$repo/scripts/bootstrap.ps1" -SuiteZip $zip -ChecksumFile $sums -DshHome "$root/home" -InstallDir "$root/private tools" -Profile test -SkipRuby
  Assert ($LASTEXITCODE -eq 1) 'existing private prefix overwritten'
  Assert ((Get-FileHash $env:TEST_NPM_LOG).Hash -eq $before) 'existing private prefix invoked npm'
  $env:TEST_NPM_EXIT = '51'
  & $engine -NoProfile -File "$repo/scripts/bootstrap.ps1" -SuiteZip $zip -ChecksumFile $sums -DshHome "$root/home" -InstallDir "$root/failure tools" -Profile test -SkipRuby
  Assert ($LASTEXITCODE -eq 51) 'npm native failure lost'
  $env:TEST_NODE_VERSION = 'v22.12.0'
  & $engine -NoProfile -File "$repo/scripts/bootstrap.ps1" -SuiteZip $zip -ChecksumFile $sums -DshHome "$root/home" -InstallDir "$root/old node" -Profile test -SkipRuby
  Assert ($LASTEXITCODE -eq 1) 'unsupported Node version accepted'
  Assert (-not (Test-Path "$root/old node")) 'unsupported Node created tool directory'
  Write-Host "PASS: missing private tools, pinned versions, existing prefix protection, npm failure, Node minimum. Artifacts: $root"
} finally { $env:PATH = $originalPath }
