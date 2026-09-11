# DSH SketchUp Bridge / SketchUp 对接套装

Standalone **DeepSeek Harness Host plugin + SketchUp Ruby extension**, with a native chat window and compatibility polyfills for SketchUp 2024's embedded Chromium.

**Independent derivative/fork:** this code was extracted from the SketchUp package in [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser), itself a fork of [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser). It is not an official SketchUp or DeepSeek product. The original **Copyright (c) 2026 Yuxiang Lin** and MIT license are preserved in [LICENSE](LICENSE). See [credits](#credits).

## 下载与安装 / Install

Download the versioned assets from [GitHub Releases](https://github.com/leolee9086/dsh-sketchup/releases). `v0.1.0-alpha.1` is a **pre-release**, not a stable compatibility guarantee.

| Asset | Purpose |
| --- | --- |
| `dsh-sketchup-0.1.0-alpha.1.zip` | Windows installation suite, including prebuilt Host tarball and Ruby files |
| `dsh-sketchup-0.1.0-alpha.1.rbz` | SketchUp Extension Manager installation |
| `leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz` | Prebuilt Host package for DSH |
| `bootstrap.ps1` | Version-pinned Windows bootstrap used by the Ruby setup menu |
| `SHA256SUMS` | SHA-256 checksums for release assets |

The npm package identity is `@leolee9086/dsh-sketchup`. For this release, install the **GitHub tarball**, not an assumed npm registry publication.

### Windows suite

Extract the ZIP, then run its `install.ps1` in PowerShell. The script registers the prebuilt package with the DSH profile and installs the extension in SketchUp's Plugins directory. See the script's parameter help for path overrides and a no-write preview. Close/save SketchUp models before restarting SketchUp to load changed Ruby files; restart DSH to load changed Host artifacts. Installation does not forcibly restart either application.

### Start from SketchUp

Install the RBZ through **Extensions → Extension Manager → Install Extension**, then use the extension's **install DSH Host** menu entry. It launches the Windows bootstrap outside SketchUp. The bootstrap verifies the fixed release's downloaded suite against `SHA256SUMS`. If DSH is missing, it installs a pinned DSH version into a private directory instead of upgrading a global installation. Internet access is required for GitHub and npm downloads.

### Start from DSH

Register the downloaded tarball with an existing DSH installation:

```powershell
dsh plugin --profile web add --save-exact ./leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz
```

The tarball contains the Ruby extension and installation scripts. Run its installer to copy the Ruby half to SketchUp; see [installation details](docs/installation.md) for exact options, backup locations and rollback. There is no hidden postinstall execution.

Windows + SketchUp **2024 (24.0.484, Ruby 3.2.2)** has been used for live bridge/chat validation. Other versions are unverified. Do not interpret a portable shell script as evidence of native SketchUp support on Linux.

## 功能 / Features

- Inspect model metadata, selection, active editing path, bounded entity geometry and audit events.
- Execute structured operations: boxes, cylinders, selection, entity deletion, active tag changes and model save.
- Route commands by explicit SketchUp instance or the current session's binding. A stale binding fails rather than silently targeting another open model.
- Open the authenticated Harness chat UI inside SketchUp.
- Install maintained `core-js/stable` polyfills **before** the native window's application module graph, including Iterator helpers, Set operations, grouping and array copy methods. Ordinary browser tabs and the Node Host are not patched. See [CEF compatibility](docs/cef-compatibility.md).
- Optionally write/reload Ruby plugin files under a scoped Plugins directory, with validation, backups and explicit gates.

```text
SketchUp Ruby extension ── local WebSocket ── DSH Host plugin
  SketchUp API / UI timer                    tools, routing, WebView
```

The default local endpoint is `ws://127.0.0.1:3080/ext/sketchup`. Geometry coordinates and tool lengths use **SketchUp internal inches**. Event history is an observer stream, not a complete internal undo stack.

## Permissions and limitations

The bundled Host patch defaults `allowPluginWrite` and `allowPluginLoad` to **false**. Enabling these permits code execution with SketchUp's privileges; `confirm: true` is also required on each write/reload call. There is no general eval command, but loading a Ruby file is still arbitrary code execution. Review source before enabling it.

The loopback check and fixed `sketchup://dsh-bridge` Origin provide a browser-origin fence; **they do not authenticate a hostile local process**. Run on a trusted local machine. The bridge sends model data to the local Harness; Harness may send it to the selected model provider under its own settings. No project files, personal conversations or credentials are included in this repository or release suite.

WebView session binding is client coordination, not an atomic authorization boundary: avoid opening the same session against different SketchUp instances concurrently. A binding failure blocks the outgoing operation; a failure after session creation cannot remove the already-created session. A failed mux bind closes that shared carrier and may interrupt its other streams. Per-instance audit history is bounded, but this alpha does not yet evict all historical disconnected instance IDs from a long-lived Host.

Model work is queued onto SketchUp's UI thread. Connection-scoped work is dropped after disconnect, network queues are bounded, and the writer has deadlines. Cancellation cannot undo a native model operation that has already started. Plugin path checks reject traversal, links and Windows aliases, but do not provide a handle-relative defense against a malicious process concurrently renaming directories. CEF polyfills cannot upgrade CSS, codecs, browser permissions or unsupported JavaScript syntax; Web Workers run in their own realm.

## Development and validation

Node **22.13+**, pnpm **11.7.0**:

```powershell
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
pnpm run build
ruby test-ruby/run.rb
```

The build bundles the ECMAScript compatibility source locally; production pages do not download a CDN polyfill. `core-js`'s optional install hook is disabled. The Ruby tests use UI/socket stubs and temporary directories; they do not modify an open SketchUp model. Windows file-symlink coverage may skip when the OS denies creation; directory-junction tests are separately exercised.

Tests cover protocol validation, routing, WebView binding, Cordis composition, missing-API behavior, queue isolation, socket framing/limits and plugin filesystem checks. Live validation confirmed the chat UI loads in SketchUp 2024 after the Iterator compatibility fix. Installer tests use disposable destinations and mock DSH commands; a clean machine installation is not implied by those tests.

## Credits

- **Yuxiang Lin / Lum1104 and dsh-browser contributors**, upstream code under MIT: [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser).
- [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser), the fork from which this standalone package was extracted.
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), Host runtime and Cordis plugin ecosystem.
- **Denis Pushkarev / core-js contributors**, maintained standard JavaScript polyfills, MIT: [core-js](https://github.com/zloirock/core-js). Its license is included at [THIRD-PARTY/core-js-LICENSE](THIRD-PARTY/core-js-LICENSE).

Standalone packaging, reliability fixes, installation suite and CEF integration are maintained here by leolee9086. Original attribution is retained; this repository does not claim exclusive authorship of the upstream bridge.
