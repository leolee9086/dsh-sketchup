# Windows installer for a source checkout, extracted release suite, or npm package.
# Requires an existing DSH CLI for Host registration; scripts/bootstrap.ps1 can install it.
[CmdletBinding()]
param(
  [string]$SourceRoot = $PSScriptRoot,
  [string]$PluginsDir = $env:SKETCHUP_PLUGINS_DIR,
  [string]$SketchUpVersion = '2024',
  [string]$DshCommand = 'dsh',
  [string]$DshHome = $env:DSH_HOME,
  [string]$Profile = 'web',
  [string]$PackagePath,
  [switch]$SkipHost,
  [switch]$SkipRuby,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# PowerShell 7's native-error preference must not replace the program's exit code.
$PSNativeCommandUseErrorActionPreference = $false
function Invoke-Checked([string]$Command, [string[]]$Arguments) {
  & $Command @Arguments | Out-Host
  if ($LASTEXITCODE -ne 0) {
    $failure = New-Object System.Exception("Command failed ($LASTEXITCODE): $Command")
    $failure.Data['ExitCode'] = $LASTEXITCODE
    throw $failure
  }
}
function Resolve-NpmCommand {
  $resolved = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $resolved) { return $null }
  # npm.ps1 may reparse MyInvocation.Statement and corrupt variable/splatted
  # calls. Prefer the sibling .cmd from the SAME PATH entry; a selected mock or
  # custom shim without that sibling remains authoritative.
  if ($resolved.Source -and (Test-Path -LiteralPath $resolved.Source -PathType Leaf)) {
    $cmd = Join-Path (Split-Path -Parent $resolved.Source) 'npm.cmd'
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return $cmd }
    return $resolved.Source
  }
  return $resolved.Name
}
function Backup-Item([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $backup = "$Path.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $Path -Destination $backup -Recurse -ErrorAction Stop
    Write-Host "Backup: $backup"
  }
}
$originalDshHome = $env:DSH_HOME
$packStage = $null
try {
  if ($SkipHost -and $SkipRuby) { throw 'Choose at least one component to install.' }
  if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $Profile -ieq 'desktop') { throw 'Invalid DSH profile name.' }
  $SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
  if (-not $DshHome) { $DshHome = Join-Path $HOME '.dsh' }
  $DshHome = [IO.Path]::GetFullPath($DshHome)
  if (-not $PluginsDir) {
    if (-not $env:APPDATA) { throw 'Specify -PluginsDir on this platform.' }
    $PluginsDir = Join-Path $env:APPDATA "SketchUp\SketchUp $SketchUpVersion\SketchUp\Plugins"
  }
  $PluginsDir = [IO.Path]::GetFullPath($PluginsDir)
  if (-not $SkipRuby) {
    foreach ($entry in @('ruby/dsh_sketchup_bridge.rb', 'ruby/dsh_sketchup_bridge/main.rb', 'ruby/dsh_sketchup_bridge/setup.rb')) {
      if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot $entry) -PathType Leaf)) { throw "Missing Ruby source: $entry" }
    }
  }
  $needsBuild = $false
  $needsPack = $false
  if (-not $SkipHost) {
    if (-not $PackagePath) {
      $tarball = Join-Path $SourceRoot 'leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz'
      $PackagePath = if (Test-Path -LiteralPath $tarball) { $tarball } else { $SourceRoot }
    }
    $PackagePath = [IO.Path]::GetFullPath($PackagePath)
    if (-not (Test-Path -LiteralPath $PackagePath)) { throw "Host package not found: $PackagePath" }
    if (Test-Path -LiteralPath $PackagePath -PathType Container) {
      $needsPack = $true
      $manifest = Get-Content -LiteralPath (Join-Path $PackagePath 'package.json') -Raw | ConvertFrom-Json
      if ($manifest.name -ne '@leolee9086/dsh-sketchup') { throw 'Unexpected Host package name.' }
      # npm 10 can run prepare even with --ignore-scripts. Never implicitly run
      # an extra source lifecycle hook while creating the durable package.
      if ($manifest.scripts -and $manifest.scripts.prepare) { throw 'Source package has a prepare script; use a prebuilt release tarball instead.' }
      $needsBuild = -not (Test-Path -LiteralPath (Join-Path $PackagePath 'lib/index.js'))
    }
  }
  Write-Host "DSH SketchUp install: Host=$(-not $SkipHost), Ruby=$(-not $SkipRuby)"
  if (-not $SkipHost) {
    Write-Host "Host: $DshCommand plugin --profile $Profile add --save-exact $PackagePath"
    Write-Host "DSH_HOME: $DshHome"
    Write-Host 'Host package will be copied into the persistent DSH_HOME/packages/dsh-sketchup cache before registration.'
    if ($needsPack) { Write-Host 'Package source: npm pack --ignore-scripts (no source-directory link)' }
    if ($needsBuild) { Write-Host 'Source build required: pnpm install --frozen-lockfile --ignore-scripts; pnpm run build' }
  }
  if (-not $SkipRuby) { Write-Host "Ruby destination: $PluginsDir (existing components receive unique backups)" }
  if ($DryRun) { Write-Host 'Dry run: no commands executed, downloads, directories, or files written.'; exit 0 }
  # Validate native commands before changing the Ruby installation.
  if (-not $SkipHost) {
    if (-not (Get-Command $DshCommand -ErrorAction SilentlyContinue)) { throw "DSH CLI not found: $DshCommand. Run scripts/bootstrap.ps1 or supply -DshCommand." }
    $npmCommand = $null
    if ($needsPack) {
      $npmCommand = Resolve-NpmCommand
      if (-not $npmCommand) { throw 'Source/package directories need npm pack; use a release tarball or install npm.' }
    }
    if ($needsBuild) {
      if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw 'Source build needs an existing pnpm installation.' }
      Push-Location $PackagePath
      try { Invoke-Checked 'pnpm' @('install', '--frozen-lockfile', '--ignore-scripts'); Invoke-Checked 'pnpm' @('run', 'build') } finally { Pop-Location }
      if (-not (Test-Path -LiteralPath (Join-Path $PackagePath 'lib/index.js'))) { throw 'Source build produced no lib/index.js.' }
    }
    if ($needsPack) {
      $packStage = Join-Path ([IO.Path]::GetTempPath()) ('dsh-sketchup-pack-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $packStage | Out-Null
      Push-Location $PackagePath
      try { Invoke-Checked $npmCommand @('pack', '--ignore-scripts', '--pack-destination', $packStage) } finally { Pop-Location }
      $archives = @(Get-ChildItem -LiteralPath $packStage -Filter '*.tgz' -File)
      if ($archives.Count -ne 1) { throw 'npm pack must produce exactly one Host tarball.' }
      $PackagePath = $archives[0].FullName
    }
    # pnpm persists file: dependencies. A temporary download/extraction path
    # would break the next profile install; always register a durable cache copy.
    $hash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $cacheDir = Join-Path $DshHome 'packages/dsh-sketchup'
    $cachedPackage = Join-Path $cacheDir "$hash.tgz"
    if (Test-Path -LiteralPath $cachedPackage) {
      if ((Get-FileHash -LiteralPath $cachedPackage -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw "Cached Host package checksum mismatch: $cachedPackage" }
    } else {
      New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
      $cacheStage = Join-Path $cacheDir ('.copy-' + [guid]::NewGuid().ToString('N'))
      try {
        Copy-Item -LiteralPath $PackagePath -Destination $cacheStage
        if ((Get-FileHash -LiteralPath $cacheStage -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Host package changed while copying.' }
        Move-Item -LiteralPath $cacheStage -Destination $cachedPackage
      } finally { if (Test-Path -LiteralPath $cacheStage) { Remove-Item -LiteralPath $cacheStage -Force } }
    }
    $PackagePath = $cachedPackage
    Write-Host "Registering durable package: $PackagePath"
    $profileDir = Join-Path (Join-Path $DshHome 'profiles') $Profile
    # Preserve user-authored profile inputs without copying its dependency tree.
    foreach ($name in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.yml', 'cordis.yaml', 'cordis.patch.yml')) {
      Backup-Item (Join-Path $profileDir $name)
    }
    $env:DSH_HOME = $DshHome
    Invoke-Checked $DshCommand @('plugin', '--profile', $Profile, 'add', '--save-exact', $PackagePath)
  }
  if (-not $SkipRuby) {
    New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
    # Stage complete replacements first. A unique backup is never removed or reused.
    $stage = Join-Path $PluginsDir ('.dsh-sketchup-stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
      Copy-Item -LiteralPath (Join-Path $SourceRoot 'ruby/dsh_sketchup_bridge.rb') -Destination $stage
      Copy-Item -LiteralPath (Join-Path $SourceRoot 'ruby/dsh_sketchup_bridge') -Destination $stage -Recurse
      $replacements = @()
      try {
        foreach ($name in @('dsh_sketchup_bridge', 'dsh_sketchup_bridge.rb')) {
          $target = Join-Path $PluginsDir $name
          if (Test-Path -LiteralPath $target) {
            $backup = "$target.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff'))-$([guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $target -Destination $backup
            Write-Host "Backup: $backup"
          } else { $backup = $null }
          $record = @{ Target = $target; Backup = $backup; Installed = $false }
          $replacements += $record
          Move-Item -LiteralPath (Join-Path $stage $name) -Destination $target
          $record.Installed = $true
        }
      } catch {
        # Restore the pair as a unit if either replacement fails. Backup copies
        # remain available even after automatic rollback, including its failure.
        $installFailure = $_
        [array]::Reverse($replacements)
        foreach ($record in $replacements) {
          try {
            if ($record.Installed) { Remove-Item -LiteralPath $record.Target -Recurse -Force }
            if ($record.Backup -and -not (Test-Path -LiteralPath $record.Target)) {
              Copy-Item -LiteralPath $record.Backup -Destination $record.Target -Recurse
            }
          } catch { Write-Warning "Restore manually from $($record.Backup): $($_.Exception.Message)" }
        }
        throw $installFailure
      }
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
  }
  Write-Host 'Installation complete. Restart the affected DSH profile and SketchUp to load the bridge.'
} catch {
  Write-Error -Message $_.Exception.Message -ErrorAction Continue
  if ($_.Exception.Data.Contains('ExitCode')) { exit [int]$_.Exception.Data['ExitCode'] }
  exit 1
} finally {
  $env:DSH_HOME = $originalDshHome
  if ($packStage -and (Test-Path -LiteralPath $packStage)) { Remove-Item -LiteralPath $packStage -Recurse -Force }
}
