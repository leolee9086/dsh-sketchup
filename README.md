# DSH SketchUp Bridge

Standalone local integration between [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) and SketchUp 2024.

This project was developed from the SketchUp work in the [`dsh-browser` fork](https://github.com/leolee9086/dsh-browser), which is based on the upstream [`Lum1104/dsh-browser`](https://github.com/Lum1104/dsh-browser). The bridge follows compatible architectural ideas and credits the upstream project and contributors. See [LICENSE](LICENSE) for the MIT terms.

## How it works

The Host package owns a loopback WebSocket server, Origin fencing, per SketchUp process routing, bounded audit history, allow-listed tools, and the authenticated native WebView surface. The Ruby extension is the only side that calls the SketchUp API. It queues model work onto SketchUp's UI thread and uses a small dependency-free RFC 6455 client.

```text
SketchUp Ruby extension -- ws://127.0.0.1:3080/ext/sketchup --> DSH Host plugin
        SketchUp API only                                      tools and WebView
```

## Install both sides

### Windows PowerShell

```powershell
.\install.ps1
```

The script builds or links the Host package into the DSH `web` profile, then installs `ruby\dsh_sketchup_bridge.rb` and its directory into the SketchUp 2024 Plugins directory. Existing files are copied to timestamped backups. Set `DSH_HOME` or `SKETCHUP_PLUGINS_DIR` when needed.

### macOS or Linux

```sh
./install.sh
```

The shell script performs the same two-sided setup. Set `SKETCHUP_PLUGINS_DIR` if the SketchUp Plugins directory is not detected.

Both installers are explicit and reversible: they do not silently download or execute code from the Ruby side, and they do not change an already running DSH or SketchUp process. Restart both applications after installation.

## Host profile

Use [cordis.patch.yml](cordis.patch.yml) in the DSH `web` profile, or let an installer register the package. `allowPluginWrite` and `allowPluginLoad` are deployment gates and default to false in the package. The sample patch enables them for local development; review that choice before using it on a shared machine.

## Tools

`sketchup_status`, `sketchup_snapshot`, `sketchup_selection`, `sketchup_history`, `sketchup_query`, `sketchup_execute`, `sketchup_write_plugin`, and `sketchup_reload_plugin` are registered by the Host package. Model commands are structured and use SketchUp internal inches. No arbitrary Ruby evaluation is exposed through the Host tools.

## Safety and privacy

The socket accepts loopback connections with the fixed `sketchup://dsh-bridge` Origin. The bridge has no cloud endpoint, telemetry, token file, or third-party upload path. It sends bounded model metadata, selections, audit events, and explicit tool results to the local DSH process. DSH's own provider and session policies still apply.

The plugin write and load capabilities are separately gated; every write or reload also requires `confirm: true`. Existing plugin files are syntax checked and backed up before replacement. Review the Host profile before enabling those capabilities.

## Development

```powershell
pnpm install
pnpm test
pnpm run typecheck
pnpm run build
```

Tests cover protocol validation, loopback and Origin fencing, multi-instance routing, tool registration, WebView binding, and Cordis composition. Live SketchUp model tests require SketchUp 2024.

## Credits

- [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser), upstream browser bridge and extension project.
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), host runtime and Cordis plugin system.
- Contributors to the `leolee9086/dsh-browser` fork, whose SketchUp bridge work and review informed this repository.
