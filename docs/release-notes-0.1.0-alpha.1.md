# v0.1.0-alpha.1 — SketchUp 独立对接套装

`@leolee9086/dsh-sketchup` 的首个打包预发布版本，包含 DeepSeek Harness Host 插件与 SketchUp Ruby 扩展。

本项目是从 [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser) 的 SketchUp 包中拆分的独立衍生版本，上游为 [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser)。保留原始 MIT 署名 **Copyright (c) 2026 Yuxiang Lin**，感谢上游作者及贡献者。core-js 垫片另附其原始 MIT 许可证。

## 本次发布内容

- 本地 WebSocket 桥接、结构化建模工具、选择集／查询／历史记录、明确的实例路由，以及经过认证的内嵌聊天窗口。
- CEF 兼容初始化脚本：通过持续维护的标准 JavaScript 垫片，修复 SketchUp 2024 加载 Harness 插件时的 `Iterator is not defined` 错误。
- 按连接隔离的 Ruby 任务队列、有大小限制的网络队列和分片、写入超时，以及加强的插件路径检查和备份处理。
- 会话绑定失效或 WebView 绑定失败时阻止继续转发，避免静默切换到其他实例。
- Windows 完整安装套装、RBZ 扩展、预编译 Host 包，以及从 Ruby 菜单启动的固定版本引导安装器。
- 可重复使用的安装脚本和备份机制，不强制重启正在编辑模型的 SketchUp。

## 安装步骤

1. 下载 `dsh-sketchup-0.1.0-alpha.1.zip`，根据 `SHA256SUMS` 校验后解压。
2. 已安装 DSH 时，运行 `install.ps1`；可先用 `-DryRun` 预览路径。其他参数见套装中的 `docs/installation.md`。
3. 也可通过 SketchUp 扩展管理器安装 RBZ，再点击 **Install DSH Host for SketchUp...**（为 SketchUp 安装 DSH Host）。需要预先安装 Node.js **22.13+** 和 npm；Windows 引导安装器可将固定版本的 DSH／pnpm 安装到独立目录。
4. 保存工作后重启 DSH 和 SketchUp，加载新组件。

仅安装 Host 时，可运行：

```powershell
dsh plugin --profile web add --save-exact ./leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz
```

本次包通过 GitHub 发布附件分发，尚未发布到 npm 软件包仓库。

## 验证结果与范围

已在 Windows + SketchUp 2024（24.0.484，内嵌 Ruby 3.2.2）中验证桥接重连，以及加载 CEF 兼容构建后的完整聊天界面。Host **63 项**测试和 Ruby **29 项**测试通过，覆盖路由、组合、会话绑定、兼容 API、队列隔离、帧处理和插件路径检查。

安装器使用临时目录与模拟 DSH 命令验证，同时已通过真实 DSH CLI 验证 Host 包安装。最终附件解压安装、离线引导流程、持久缓存和远端下载校验均已检查。这些结果不等于全新电脑上的完整安装认证。

Windows 文件符号链接测试在系统不允许创建时会跳过；真实目录联接测试已另行执行。其他 SketchUp 版本、macOS，以及各个 PDF／Worker 渲染路径尚未完成实测。

## 权限说明

插件写入与加载权限默认**关闭**。即使没有通用 eval 工具，加载 Ruby 仍会以 SketchUp 的权限执行代码。回环地址与 Origin 限制不能验证恶意本地进程的身份。查询的模型信息是否发给模型提供方，取决于 Harness 的相关设置。启用高权限操作前，请阅读 README 中的限制说明。
