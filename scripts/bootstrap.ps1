# Fixed-release Windows bootstrap. Run with PowerShell 5.1+ and Node.js >=22.13.
# DSH/pnpm are reused when present; missing tools go into a private versioned prefix.
[CmdletBinding()]
param(
  [string]$DshCommand = 'dsh',
  [string]$DshHome = $env:DSH_HOME,
  [string]$InstallDir,
  [string]$PluginsDir = $env:SKETCHUP_PLUGINS_DIR,
  [string]$Profile = 'web',
  [string]$SuiteZip,
  [string]$ChecksumFile,
  [switch]$SkipRuby,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$version = '0.1.0-alpha.1'
$dshVersion = '0.1.5-rc.2'
$pnpmVersion = '11.7.0'
$asset = "dsh-sketchup-$version.zip"
$release = "https://github.com/leolee9086/dsh-sketchup/releases/download/v$version"
$originalPath = $env:PATH
$tempRoot = $null
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
  # Avoid npm.ps1 reparsing a variable/splatted invocation. Resolve the sibling
  # .cmd only within the selected PATH entry so mock/custom commands still work.
  if ($resolved.Source -and (Test-Path -LiteralPath $resolved.Source -PathType Leaf)) {
    $cmd = Join-Path (Split-Path -Parent $resolved.Source) 'npm.cmd'
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return $cmd }
    return $resolved.Source
  }
  return $resolved.Name
}
# Follow GitHub's asset redirects, but reject every non-HTTPS hop.
function Get-HttpsFile([string]$Url, [string]$Destination, [long]$MaxBytes) {
  $uri = [uri]$Url
  for ($redirect = 0; $redirect -le 8; $redirect++) {
    if ($uri.Scheme -ne 'https') { throw 'Download refused: HTTPS is required.' }
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.UserAgent = 'dsh-sketchup-installer/0.1.0-alpha.1'
    $response = $request.GetResponse()
    try {
      $status = [int]$response.StatusCode
      if ($status -ge 300 -and $status -lt 400) {
        $location = $response.Headers['Location']
        if (-not $location) { throw 'Redirect has no Location header.' }
        $uri = New-Object System.Uri($uri, $location)
        continue
      }
      if ($status -ne 200) { throw "Download HTTP status: $status" }
      if ($response.ContentLength -gt $MaxBytes) { throw 'Download exceeds size limit.' }
      $inputStream = $response.GetResponseStream()
      $outputStream = [IO.File]::Create($Destination)
      try {
        $buffer = New-Object byte[] 65536
        [long]$total = 0
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
          $total += $count
          if ($total -gt $MaxBytes) { throw 'Download exceeds size limit.' }
          $outputStream.Write($buffer, 0, $count)
        }
      } finally { $outputStream.Dispose(); $inputStream.Dispose() }
      return
    } finally { $response.Dispose() }
  }
  throw 'Too many download redirects.'
}
try {
  if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $Profile -ieq 'desktop') { throw 'Invalid profile name.' }
  if ([bool]$SuiteZip -ne [bool]$ChecksumFile) { throw 'Provide both -SuiteZip and -ChecksumFile for an offline release.' }
  if (-not $DshHome) { $DshHome = Join-Path $HOME '.dsh' }
  if (-not $InstallDir) { $InstallDir = Join-Path $DshHome "tools/sketchup-bootstrap-dsh-$dshVersion-pnpm-$pnpmVersion" }
  $InstallDir = [IO.Path]::GetFullPath($InstallDir)
  if ($SuiteZip) { $SuiteZip = [IO.Path]::GetFullPath($SuiteZip); $ChecksumFile = [IO.Path]::GetFullPath($ChecksumFile) }
  Write-Host "Release: $release/$asset"
  Write-Host "Target: DSH_HOME=$DshHome, profile=$Profile; private missing-tool prefix=$InstallDir"
  Write-Host 'Requires existing Node.js >=22.13 and npm. Existing DSH/pnpm installations are never upgraded.'
  if ($DryRun) { Write-Host 'Dry run: no download, tool execution, directory creation, or file writes.'; exit 0 }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js >=22.13 and npm, then run this installer again.' }
  $nodeVersion = & node --version
  if ($LASTEXITCODE -ne 0) {
    $failure = New-Object System.Exception('Cannot read Node.js version.')
    $failure.Data['ExitCode'] = $LASTEXITCODE
    throw $failure
  }
  if ($nodeVersion -notmatch '^v(\d+)\.(\d+)\.' -or [int]$Matches[1] -lt 22 -or ([int]$Matches[1] -eq 22 -and [int]$Matches[2] -lt 13)) { throw 'Node.js >=22.13 is required; the installer does not upgrade Node.js.' }
  $dshFound = Get-Command $DshCommand -ErrorAction SilentlyContinue
  if (-not $dshFound -and $DshCommand -ne 'dsh') { throw "Explicit DSH command not found: $DshCommand" }
  $pnpmFound = Get-Command pnpm -ErrorAction SilentlyContinue
  # Verify and unpack the release before installing anything into the DSH home.
  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-sketchup-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  if (-not $SuiteZip) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $SuiteZip = Join-Path $tempRoot $asset
    $ChecksumFile = Join-Path $tempRoot 'SHA256SUMS'
    Get-HttpsFile "$release/SHA256SUMS" $ChecksumFile 1048576
    Get-HttpsFile "$release/$asset" $SuiteZip 1073741824
  }
  $pattern = '^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($asset) + '$'
  $hashes = @(Get-Content -LiteralPath $ChecksumFile | ForEach-Object { if ($_ -match $pattern) { $Matches[1].ToLowerInvariant() } })
  if ($hashes.Count -ne 1) { throw "SHA256SUMS must contain exactly one entry for $asset." }
  if ((Get-FileHash -LiteralPath $SuiteZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[0]) { throw 'Release SHA256 checksum mismatch.' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $extract = Join-Path $tempRoot 'suite'
  New-Item -ItemType Directory -Path $extract | Out-Null
  $zip = [IO.Compression.ZipFile]::OpenRead($SuiteZip)
  try {
    [long]$expandedBytes = 0
    foreach ($entry in $zip.Entries) {
      $expandedBytes += $entry.Length
      if ($expandedBytes -gt 2147483648) { throw 'Expanded suite exceeds size limit.' }
      if ($entry.FullName -match '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)') { throw 'Unsafe path in release archive.' }
      $entryPath = [IO.Path]::GetFullPath((Join-Path $extract $entry.FullName))
      if (-not $entryPath.StartsWith($extract + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe path in release archive.' }
    }
  } finally { $zip.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory($SuiteZip, $extract)
  $installer = Join-Path $extract 'install.ps1'
  if (-not (Test-Path -LiteralPath $installer)) { throw 'Release archive must contain install.ps1 at its root.' }
  $tarball = Join-Path $extract "leolee9086-dsh-sketchup-$version.tgz"
  if (-not (Test-Path -LiteralPath $tarball)) { throw 'Release archive contains no prebuilt Host tarball.' }
  $packages = @()
  if (-not $dshFound) { $packages += "@deepseek-ai/dsh@$dshVersion" }
  if (-not $pnpmFound) { $packages += "pnpm@$pnpmVersion" }
  if ($packages.Count -gt 0) {
    $npmCommand = Resolve-NpmCommand
    if (-not $npmCommand) { throw 'npm is required to install missing private tools.' }
    # Never reuse/alter an existing tool prefix, even if a prior installation failed.
    if (Test-Path -LiteralPath $InstallDir) { throw "Private tool directory already exists: $InstallDir. Supply a new -InstallDir, or supply its existing dsh with -DshCommand and pnpm on PATH." }
    Invoke-Checked $npmCommand (@('install', '--prefix', $InstallDir, '--no-audit', '--no-fund', '--save-exact') + $packages)
    $env:PATH = (Join-Path $InstallDir 'node_modules/.bin') + [IO.Path]::PathSeparator + $env:PATH
  }
  if (-not $dshFound) { $DshCommand = Join-Path $InstallDir 'node_modules/.bin/dsh.cmd' }
  elseif ($dshFound.Source) { $DshCommand = $dshFound.Source }
  $engine = Join-Path $PSHOME 'powershell.exe'
  if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'pwsh.exe' }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer, '-SourceRoot', $extract, '-DshCommand', $DshCommand, '-DshHome', $DshHome, '-Profile', $Profile, '-PackagePath', $tarball)
  if ($PluginsDir) { $arguments += @('-PluginsDir', $PluginsDir) }
  if ($SkipRuby) { $arguments += '-SkipRuby' }
  Invoke-Checked $engine $arguments
  Write-Host "Host installed. Start it with: & '$DshCommand' --profile '$Profile'"
  if ($packages.Count -gt 0) { Write-Host "For future terminals, add to PATH: $(Join-Path $InstallDir 'node_modules/.bin')" }
  Write-Host "Use DSH_HOME=$DshHome when starting this profile. Configure a model provider in DSH if this is a new installation."
} catch {
  Write-Error -Message $_.Exception.Message -ErrorAction Continue
  if ($_.Exception.Data.Contains('ExitCode')) { exit [int]$_.Exception.Data['ExitCode'] }
  exit 1
} finally {
  $env:PATH = $originalPath
  if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
