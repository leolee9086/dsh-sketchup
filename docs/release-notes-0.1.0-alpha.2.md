# v0.1.0-alpha.2

兼容 DSH 0.2.1-rc.5 的修复版。**v0.1.0-alpha.1 在 0.2.1-rc.5 上装不上**，因为它声明的 peerDependencies 还是 `^0.1.2-alpha.2`，会被版本门禁直接拒绝。

## 修复

- `peerDependencies` 升到 `^0.2.1-rc.5`（`@deepseek-ai/dsh-invariants` 按实际可用版本写作 `^0.2.0-rc.2`），`devDependencies` 同步。
- `@deepseek-ai/schemastery` 锁定 `3.18.6-alpha.2`（与 DSH 运行时一致）。用 npm 上的 3.18.5 时 `z<Config>` 注解与 `default()` 产生的 `Volatile` 类型不匹配，编译失败。
- **端口发现**：原来 Ruby 扩展写死连 `ws://127.0.0.1:3080`，而 Host 挂在 DSH 自己的 webServer 端口（不固定），永远连不上。现在 Host 启动时把 `wsUrl` 写进 `%LOCALAPPDATA%\dsh-sketchup\bridge.json`，Ruby 扩展启动读它；`DSH_SKETCHUP_PORT` 仍可覆盖，两者都没有才回退 3080。
- Ruby 侧版本号同步到 `0.1.0-alpha.2`。

## 验证

- 构建通过；63 项 TS 测试全过。
- 真机：DSH 桌面 0.2.1-rc.5 + SketchUp 2024（24.0.484，Ruby 3.2.2）。`sketchup_status` 返回已连接；`sketchup_snapshot` 读到模型实体；`sketchup_execute` 的 `add_box` 建成 `DSH Box` 24×24×24 英寸，实体数 1→2。

## 安装

GitHub 发布页下载对应附件，或者从本仓库源码安装；\`@leolee9086/dsh-sketchup\` 尚未发布到 npm。

- DSH 侧：`plugin_manager` 的 `install_bundle` 指向包目录或 tgz。
- SketchUp 侧：装 `dsh-sketchup-0.1.0-alpha.2.rbz`，或用 ZIP 套件里的 `install.ps1`。

## 已知问题

- 内嵌 WebView 聊天（CEF 垫片）本轮未验证。
- 只在 Windows + SketchUp 2024 实测。
