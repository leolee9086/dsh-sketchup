# Installing the SketchUp + DSH suite

This alpha supports Windows with SketchUp 2024. Windows setup needs PowerShell 5.1 or later. The Host bootstrap needs **Node.js 22.13 or later and npm already installed**. It does not install or upgrade Node.js, SketchUp, or unrelated software. A new DSH installation also needs a model provider configured before it can answer requests.

The `install.sh` path is limited to an existing DSH and pnpm installation on macOS; it does not bootstrap DSH. It has been tested with mock commands under Bash, not with SketchUp on macOS. Linux is not a supported SketchUp platform.

No installer starts, stops, or restarts a running DSH or SketchUp process. Restart the affected applications yourself after installing bridge files. The Ruby Host setup menu keeps SketchUp usable while installation runs in an external PowerShell window.

## Windows: install the suite into existing DSH

Download and extract `dsh-sketchup-0.1.0-alpha.1.zip` from the [v0.1.0-alpha.1 release](https://github.com/leolee9086/dsh-sketchup/releases/tag/v0.1.0-alpha.1). The ZIP contains `install.ps1`, `install.sh`, `ruby/`, `scripts/`, and the prebuilt `leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz`. Keep these together.

From the extracted directory:

```powershell
# Preview: no downloads, builds, CLI calls, directories, or files written.
.\install.ps1 -DryRun

# Install the Host bundle in the web profile and the Ruby bridge in SketchUp 2024.
.\install.ps1

# Explicit paths, including paths containing spaces.
.\install.ps1 -PluginsDir 'D:\SketchUp Plugins' `
  -DshCommand 'D:\DSH tools\dsh.cmd' -DshHome 'D:\DSH home' -Profile web
```

The installer invokes the actual DSH CLI form:

```text
dsh plugin --profile web add --save-exact <absolute-package-path>
```

DSH installs the package and registers its `dsh.bundle` profile layer. Before registration, the installer copies the tarball into `DSH_HOME/packages/dsh-sketchup/<sha256>.tgz`, checks its contents, and registers that durable path. Source/package directories are first packed with `npm pack --ignore-scripts`. The saved dependency remains usable after downloaded ZIPs and extraction directories are removed. Existing cache entries are verified and never overwritten with different contents. There is no extra composition edit and no `dsh cli plugin` command. The selected profile lives below `DSH_HOME/profiles/<profile>`.

`install.ps1` parameters:

| Parameter | Default / effect |
| --- | --- |
| `-SourceRoot PATH` | Directory containing the installer; supplies `ruby/` and the default Host package. |
| `-PluginsDir PATH` | `SKETCHUP_PLUGINS_DIR`, otherwise `%APPDATA%\SketchUp\SketchUp 2024\SketchUp\Plugins`. Creates the destination when needed. |
| `-SketchUpVersion YEAR` | `2024`; affects only the default Plugins path. Other versions are not verified. |
| `-DshCommand PATH` | `dsh` resolved on PATH; an explicit executable/script path is accepted. |
| `-DshHome PATH` | `DSH_HOME`, otherwise `$HOME/.dsh`; passed to the DSH child process. |
| `-Profile NAME` | `web`; profile names accept letters, digits, periods, underscores and hyphens, beginning with a letter or digit. |
| `-PackagePath PATH` | Explicit local tarball or package directory. Otherwise uses the named release tarball at the source root, or the source root itself. |
| `-SkipHost` | Only install the Ruby extension; no DSH command is needed. |
| `-SkipRuby` | Only install the Host bundle. |
| `-DryRun` | Validate local inputs and print the plan without writes or subprocesses. |

`-SkipHost` and `-SkipRuby` cannot both be selected. An invalid or missing explicit path fails rather than silently switching to another installation.

## Host to Ruby

The npm package includes the Ruby files and installers. In the installed package directory (or an extracted source/release suite), run:

```powershell
.\install.ps1 -SkipHost -PluginsDir 'C:\Users\YOUR_NAME\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins'
```

This installs both the root `dsh_sketchup_bridge.rb` loader and the `dsh_sketchup_bridge/` directory. Restart SketchUp to register the extension. An alternative is SketchUp's Extension Manager → Install Extension → select the release RBZ.

## Ruby to Host

After installing the RBZ or Ruby files, choose **Extensions → Install DSH Host for SketchUp...**. Enter the DSH profile, DSH home, DSH executable (`dsh` by default), and optionally a private tool directory.

The menu downloads `bootstrap.ps1` and `SHA256SUMS` from the fixed `v0.1.0-alpha.1` GitHub release over HTTPS, verifies the bootstrap SHA256, then starts a separate PowerShell process with encoded, quoted literal arguments. Network work runs outside SketchUp's UI thread. The bootstrap downloads the fixed release suite ZIP and verifies its SHA256 before extracting or executing it. HTTPS is checked on every redirect. SHA256SUMS provides release transport/integrity verification; it is not an independent signature or publisher identity proof.

The bootstrap reuses DSH and pnpm when they are already on PATH. If tools are missing, it installs only those missing tools with npm into a private prefix:

```text
<DSH_HOME>/tools/sketchup-bootstrap-dsh-0.1.5-rc.2-pnpm-11.7.0
```

The pinned missing-tool packages are `@deepseek-ai/dsh@0.1.5-rc.2` and `pnpm@11.7.0`. It never runs a global npm upgrade or replaces an existing private prefix. For a retry after a partial private install, pass a new `-InstallDir`, or explicitly select the existing working DSH executable and put its pnpm directory on PATH.

The Ruby menu passes `-SkipRuby`, since the Ruby extension is already installed. Installation results and the exact Host start command appear in the external PowerShell window. Keep `DSH_HOME` set to the selected directory when starting that profile. For a private install, add its `node_modules/.bin` directory to PATH in future terminals so DSH can find pnpm.

You can also run the verified bootstrap directly:

```powershell
.\scripts\bootstrap.ps1 -DryRun
.\scripts\bootstrap.ps1 -DshHome 'D:\DSH home' -Profile web `
  -PluginsDir 'D:\SketchUp Plugins'

# Local release files still require a matching checksum entry for the fixed ZIP name.
.\scripts\bootstrap.ps1 -SuiteZip 'D:\Downloads\dsh-sketchup-0.1.0-alpha.1.zip' `
  -ChecksumFile 'D:\Downloads\SHA256SUMS' -DshCommand 'D:\Tools\dsh.cmd' -SkipRuby
```

Bootstrap parameters are `-DshCommand`, `-DshHome`, `-InstallDir`, `-PluginsDir`, `-Profile`, `-SuiteZip`, `-ChecksumFile`, `-SkipRuby`, and `-DryRun`. Supply `-SuiteZip` and `-ChecksumFile` together. The downloaded bootstrap temp directory is retained by the Ruby launcher so the external process can read it and errors can be diagnosed; the bootstrap cleans up its own extracted suite temp directory.

## Source checkout

`install.ps1` also accepts a source checkout. If the selected package directory has no `lib/index.js`, it uses existing pnpm to run `pnpm install --frozen-lockfile --ignore-scripts` followed by `pnpm run build`. Build errors propagate and stop installation. An already-built checkout is used as-is and packed with `npm pack --ignore-scripts`; run `pnpm run build` yourself after changing source files. Source/package-directory installation requires npm to create this durable package instead of linking the original directory. Source manifests with a `prepare` script are rejected because npm 10 can execute that hook despite `--ignore-scripts`; use the release tarball in that case. The explicit `pnpm run build` step executes the checkout's trusted build script. The release suite uses its prebuilt tarball and does not build on the destination computer.

```powershell
.\install.ps1 -SourceRoot 'D:\dev\dsh-sketchup' -Profile web
```

## Backups, recovery, and migration

Before running the DSH package command, the installer copies existing profile inputs (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `cordis.yml`, `cordis.yaml`, and `cordis.patch.yml`) to uniquely named adjacent `.bak-...` paths. It does not copy `node_modules`. A failed DSH package command returns its original exit code and stops before Ruby replacement; DSH/pnpm may already have changed profile dependencies, so inspect the preserved inputs when recovering a failed package installation.

Existing Ruby loader and directory are moved into distinct `.bak-...` paths before replacement. Windows uses a timestamp plus random identifier; Bash atomically reserves a unique backup directory with its old content under `original`. Existing backups are never deleted or overwritten. Windows rolls back both Ruby components if either replacement fails, retaining the backups. Bash restores a failed component and retains all earlier component backups for manual recovery.

To roll back, close the affected application, move the newly installed Ruby loader/directory aside, and copy the matching backup pair into their original names. For Host recovery, restore the desired profile input backups and run `dsh plugin --profile <profile> install --frozen-lockfile` with the same `DSH_HOME` to reconcile dependencies. Backups are retained until you explicitly decide to remove them.

This package is named `@leolee9086/dsh-sketchup`. If a previous SketchUp Host package or manually registered SketchUp composition is already active, remove that old SketchUp registration before enabling this one; two Host bridges can register the same route. Check your profile's package manifest for the actual old package name and use `dsh plugin --profile <profile> remove <old-package>` where applicable. The installers do not automatically delete older packages or manually authored compositions.

## macOS: existing DSH only

```bash
bash install.sh --dry-run
bash install.sh --plugins-dir "$HOME/Library/Application Support/SketchUp 2024/SketchUp/Plugins" \
  --dsh-command /path/to/dsh --dsh-home "$HOME/.dsh" --profile web
```

Accepted flags are `--source-root`, `--plugins-dir`, `--dsh-command`, `--dsh-home`, `--profile`, `--package-path`, `--skip-host`, `--skip-ruby`, `--dry-run`, and `--help`. Source build and tarball selection match the Windows installer. No automatic Host bootstrap is offered from the macOS Ruby menu.
