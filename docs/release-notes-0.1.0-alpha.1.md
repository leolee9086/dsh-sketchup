# v0.1.0-alpha.1 — standalone SketchUp bridge suite

First packaged pre-release of `@leolee9086/dsh-sketchup`, combining the DeepSeek Harness Host plugin and SketchUp Ruby extension.

This is an independent derivative of the SketchUp package from [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser), based on [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser). Original MIT attribution **Copyright (c) 2026 Yuxiang Lin** is preserved. Thanks to the upstream authors and contributors. `core-js` polyfills retain their separate MIT license.

## Included

- Local WebSocket bridge, structured model tools, selection/query/history, explicit instance routing, and native authenticated chat window.
- CEF compatibility prelude that fixes `Iterator is not defined` during Harness plugin loading in SketchUp 2024, with maintained standard JavaScript polyfills.
- Connection-scoped Ruby task queues, bounded network queues/fragments, writer deadlines, and stronger plugin path/backup handling.
- Fail-closed handling of stale session bindings and WebView binding failures.
- Windows installation suite, RBZ extension, prebuilt Host tarball, and Ruby menu that launches a checked, version-pinned Windows bootstrap.
- Reusable install scripts and backups; no forced restart of open SketchUp models.

## Installation

1. Download `dsh-sketchup-0.1.0-alpha.1.zip`, check it against `SHA256SUMS`, and extract it.
2. With DSH already installed, run `install.ps1`; use `-DryRun` to preview paths. See `docs/installation.md` for overrides.
3. Alternatively install the RBZ in SketchUp Extension Manager and use **Install DSH Host for SketchUp...**. Node.js 22+ and npm are prerequisites; the Windows bootstrap can install pinned DSH/pnpm into a private directory.
4. Restart DSH and SketchUp when ready to load the new components.

For a Host-only installation: `dsh plugin --profile web add --save-exact ./leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz`. The package is distributed as a GitHub release asset; this release does not claim an npm registry publication.

## Validation and scope

Windows + SketchUp 2024 (24.0.484, embedded Ruby 3.2.2): live bridge reconnection and the complete native chat UI were verified after loading the CEF compatibility build. Automated Host and Ruby tests cover routing, composition, session binding, compatibility APIs, queue isolation, socket framing and plugin path handling. Installer behavior is tested using temporary destinations and mocked DSH commands. This is not a clean-machine installation certification.

One Windows file-symlink test fixture may skip without OS privileges; real directory-junction tests were exercised separately. Other SketchUp releases, macOS, and individual PDF/Worker rendering paths remain unverified.

## Permissions

Plugin write/load gates default to **off**. Loading Ruby executes code with SketchUp privileges even though no general eval tool is exposed. The loopback/Origin fence is not authentication against hostile local processes. Harness provider settings determine whether queried model information is sent to a model provider. Read the README limitations before enabling high-privilege operations.
