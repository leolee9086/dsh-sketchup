# DSH SketchUp 对接套装

独立的 **DeepSeek Harness Host 插件 + SketchUp Ruby 扩展**，提供 SketchUp 内嵌聊天窗口，并为 SketchUp 2024 自带的 Chromium 补充所需的兼容垫片。

**项目来源：独立衍生版本（fork）。** 本项目从 [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser) 的 SketchUp 包中拆分，该仓库源自 [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser)。本项目不是 SketchUp 或 DeepSeek 官方产品。[LICENSE](LICENSE) 中保留了原始 **Copyright (c) 2026 Yuxiang Lin** 版权声明及 MIT 许可证，详见[致谢](#致谢)。

## 下载与安装

请从 [GitHub 发布页](https://github.com/leolee9086/dsh-sketchup/releases) 下载对应版本的附件。`v0.1.0-alpha.1` 为**预发布版**，兼容性仍需进一步验证。

| 文件 | 用途 |
| --- | --- |
| `dsh-sketchup-0.1.0-alpha.1.zip` | Windows 完整安装套装，内含预编译 Host 包与 Ruby 扩展 |
| `dsh-sketchup-0.1.0-alpha.1.rbz` | 通过 SketchUp 扩展管理器安装的扩展包 |
| `leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz` | DSH 使用的预编译 Host 插件包 |
| `bootstrap.ps1` | Ruby 安装菜单调用的 Windows 引导安装器，固定安装版本 |
| `SHA256SUMS` | 发布附件的 SHA-256 校验和 |

包名为 `@leolee9086/dsh-sketchup`。本次通过 **GitHub 发布附件**分发，尚未发布到 npm 软件包仓库，请使用下载的 TGZ 安装。

### 使用 Windows 完整套装

解压 ZIP 后，在 PowerShell 中运行 `install.ps1`。脚本会把预编译 Host 包登记到 DSH profile，并将 Ruby 扩展安装到 SketchUp 的 Plugins 目录。可通过参数指定安装路径，也可用 `-DryRun` 预览操作而不写入文件。

安装完成后，重启 DSH 以加载新的 Host 文件；保存模型并重启 SketchUp 以加载新的 Ruby 文件。安装器不会强制重启应用。

### 从 SketchUp 安装 Host

在 SketchUp 中通过**扩展程序 → 扩展管理器 → 安装扩展程序**安装 RBZ，然后选择扩展菜单中的 **Install DSH Host for SketchUp...**（为 SketchUp 安装 DSH Host）。安装过程会在独立的 PowerShell 窗口中运行。

引导安装器根据 `SHA256SUMS` 校验固定版本的安装套装。若本机缺少 DSH，则将固定版本安装到独立目录，不升级已有的全局安装。需要预先安装 **Node.js 22.13+ 和 npm**，并能够访问 GitHub 和 npm。

### 从 DSH 安装 Ruby 扩展

已有 DSH 时，可先登记下载的 Host 包：

```powershell
dsh plugin --profile web add --save-exact ./leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz
```

包内包含 Ruby 扩展及安装脚本。运行安装器即可将 Ruby 部分复制到 SketchUp；具体参数、备份位置和回滚方法见[安装指南](docs/installation.md)。安装脚本需要显式运行，没有隐藏的安装后自动执行步骤。

目前已在 Windows + SketchUp **2024（24.0.484，Ruby 3.2.2）** 中验证桥接和内嵌聊天。其他版本尚未实测。提供 Bash 脚本并不代表 SketchUp 支持 Linux。

## 功能

- 读取模型信息、选择集、当前编辑路径、限量实体几何信息和审计事件。
- 执行结构化操作：创建长方体或圆柱体、选择或删除实体、切换活动标签、保存模型。
- 按明确指定的 SketchUp 实例或当前会话绑定分发指令。绑定的实例断线时会报错，不会悄悄转发到另一个已打开的模型。
- 在 SketchUp 内打开经过认证的 Harness 聊天界面。
- 在内嵌窗口的应用模块加载**之前**执行 `core-js/stable` 垫片，补充 Iterator、Set 运算、分组、数组复制方法等标准 API；普通浏览器标签页和 Node Host 不受影响。详见 [CEF 兼容说明](docs/cef-compatibility.md)。
- 按需启用指定 Plugins 子目录内的 Ruby 插件写入与重新加载，包含校验、备份和显式权限开关。

```text
SketchUp Ruby 扩展 ── 本地 WebSocket ── DSH Host 插件
  SketchUp API／界面定时器              工具、实例路由、内嵌网页
```

默认本地地址为 `ws://127.0.0.1:3080/ext/sketchup`。几何坐标和工具长度统一使用 **SketchUp 内部单位：英寸**。事件历史来自观察器回调，不等于完整的内部撤销记录。

## 权限与已知限制

随包提供的 Host 配置将 `allowPluginWrite` 和 `allowPluginLoad` 默认设为 **false**。启用后，Ruby 代码可以使用 SketchUp 的进程权限；每次写入或重新加载还需传入 `confirm: true`。虽然没有通用 eval 命令，加载 Ruby 文件仍属于代码执行，启用前应检查源码。

回环地址检查与固定的 `sketchup://dsh-bridge` Origin 用于限制浏览器来源，**不能验证恶意本地进程的身份**，因此应在可信本机环境使用。桥接将模型数据发送给本地 Harness；Harness 可能按照所选模型服务和自身设置将数据发送给模型提供方。本仓库和发布套装不包含个人工程、会话记录或凭证。

WebView 会话绑定属于客户端协调机制，不是原子化的权限边界。请避免在多个窗口中将同一会话同时绑定到不同 SketchUp 实例。绑定失败会阻止后续操作；若会话已经创建，随后的绑定失败不会删除该会话。复用连接中的绑定失败会关闭共享连接，也可能中断其中的其他流。每个实例的事件历史有数量上限，但当前 alpha 尚未清理长期运行 Host 中的所有已断线实例标识。

模型操作在 SketchUp 界面线程上排队执行。断线后会丢弃该连接尚未执行的任务，网络队列有大小上限，写入也有超时限制。取消操作无法撤销已经开始的原生模型修改。插件路径检查会拒绝目录穿越、链接和 Windows 路径别名，但不能完全防御恶意进程同时重命名目录造成的竞争条件。CEF 垫片不能升级 CSS、编解码器、浏览器权限或不支持的 JavaScript 语法；Web Worker 拥有独立运行环境，需要单独处理兼容性。

## 开发与验证

需要 Node.js **22.13+**、pnpm **11.7.0**：

```powershell
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
pnpm run build
ruby test-ruby/run.rb
```

构建时会把标准 JavaScript 兼容代码打包到本地文件，运行页面不从 CDN 下载垫片。`core-js` 仅作为构建依赖，其可选安装钩子已禁用。Ruby 测试使用模拟界面、模拟连接和临时目录，不会修改正在打开的 SketchUp 模型。Windows 若不允许创建文件符号链接，相应测试会跳过；目录联接测试另行执行。

测试覆盖协议校验、实例路由、WebView 绑定、Cordis 组合、缺失 API 的行为、队列隔离、WebSocket 帧及大小限制、插件文件系统检查。实际运行已确认：加入 Iterator 兼容修复后，SketchUp 2024 能加载完整聊天界面。安装器测试使用临时目录和模拟 DSH 命令，另已通过真实 DSH CLI 验证 Host 包安装；这些验证不等于全新电脑上的完整安装认证。

## 致谢

- **Yuxiang Lin／Lum1104 与 dsh-browser 贡献者**：提供 MIT 许可的上游代码，[Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser)。
- [leolee9086/dsh-browser](https://github.com/leolee9086/dsh-browser)：本独立包拆分时所依据的 fork。
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：提供 Host 运行时及 Cordis 插件生态。
- **Denis Pushkarev 与 core-js 贡献者**：维护标准 JavaScript 垫片，[core-js](https://github.com/zloirock/core-js)，采用 MIT 许可证；原文保存在 [THIRD-PARTY/core-js-LICENSE](THIRD-PARTY/core-js-LICENSE)。

本仓库由 leolee9086 维护独立打包、可靠性修复、安装套装和 CEF 兼容集成。上游署名完整保留，不将上游桥接代码宣称为本仓库独有原创。
