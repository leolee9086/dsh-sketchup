# Installer regression checks

Run from a Windows checkout. These checks install only mocked tools/packages into newly created temporary directories; `npm-shim-tests.ps1` additionally invokes the real local npm executable to pack a temporary fixture, with no registry installation. They do not invoke the real DSH CLI, register anything in a live profile, or modify an installed SketchUp extension. Temporary fixtures are retained and their paths printed for inspection. Run each script in a child process, not by dot-sourcing it into your shell.

```powershell
# PowerShell 7 installer paths, including source packing/build, backups and rollback.
pwsh -NoProfile -File test-install/installer-tests.ps1

# The same installer cases executed by native Windows PowerShell 5.1.
pwsh -NoProfile -File test-install/installer-tests.ps1 -PowerShellCommand powershell.exe

# Missing DSH/pnpm branch: isolated PATH, mocked Node/npm and private prefix.
pwsh -NoProfile -File test-install/bootstrap-private-tests.ps1

# Actual Windows npm.cmd --version/local pack; source with prepare is rejected.
pwsh -NoProfile -File test-install/npm-shim-tests.ps1
pwsh -NoProfile -File test-install/npm-shim-tests.ps1 -PowerShellCommand powershell.exe

# Ruby 3.2+ with PowerShell available as pwsh on PATH.
ruby test-install/ruby-installer-tests.rb

# Existing-DSH shell path; tested with Git Bash on Windows.
& 'C:\Program Files\Git\bin\bash.exe' test-install/shell-installer-tests.sh
```

`PWSH_COMMAND` can override the executable used by the Ruby argument-escaping test. Windows production setup still launches the system Windows PowerShell executable.

The Windows suite checks zero-write dry runs, explicit paths with spaces, exact CLI flags and DSH_HOME, persistent SHA256-addressed package cache, unique backups, restoration of both Ruby components when a locked loader causes failure, source build failure propagation, suppressed dependency lifecycle scripts, prebuilt tarball selection, verified ZIP bootstrap, persistence after extraction cleanup, checksum rejection, and native exit codes 29/37/43.

The private-tool suite checks pinned DSH/pnpm package arguments, no global npm flag, refusal to overwrite an existing private prefix, native npm exit 51, and the Node 22.13 minimum. Node and npm are mocked; no package download occurs.

The Ruby suite checks menu registration idempotency, matching/mismatching/duplicate checksum entries, rejection of HTTP URLs, and executes the generated encoded PowerShell launcher against a harmless script to prove that apostrophes, spaces, ampersands and `$()` strings remain literal argument values.

The Bash suite checks source and release installs, durable cache, unique backups, dry-run behavior, exact CLI arguments, DSH_HOME, and propagation of native failure status 31. It does not validate SketchUp behavior on macOS. Use `bash -n install.sh` for an additional syntax-only check.

Online GitHub download availability and actual clean-machine npm provisioning are outside these mock checks. Release asset names and SHA256SUMS must be verified when publishing.
