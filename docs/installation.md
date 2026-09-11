# 安装 SketchUp + DSH 套件

此 alpha 版本支持 Windows 上的 SketchUp 2024。Windows 安装需要 PowerShell 5.1 或更高版本。Host 引导安装要求**已安装 Node.js 22.13 或更高版本以及 npm**。它不会安装或升级 Node.js、SketchUp 或其他无关软件。全新安装的 DSH 还需要配置模型提供商，才能响应请求。

`install.sh` 安装方式仅适用于 macOS 上已安装 DSH 和 pnpm 的环境；它不会引导安装 DSH。目前仅在 Bash 下使用模拟命令测试过此方式，尚未在 macOS 上结合 SketchUp 测试。Linux 不是 SketchUp 支持的平台。

任何安装程序都不会启动、停止或重启正在运行的 DSH 或 SketchUp 进程。安装桥接文件后，请自行重启受影响的应用程序。Ruby 的 Host 安装菜单会在独立的 PowerShell 窗口中执行安装，期间仍可使用 SketchUp。

## Windows：将套件安装到现有 DSH 环境

从 [v0.1.0-alpha.1 发布页](https://github.com/leolee9086/dsh-sketchup/releases/tag/v0.1.0-alpha.1)下载并解压 `dsh-sketchup-0.1.0-alpha.1.zip`。ZIP 包含 `install.ps1`、`install.sh`、`ruby/`、`scripts/` 和预构建的 `leolee9086-dsh-sketchup-0.1.0-alpha.1.tgz`。请保持这些文件和目录放在一起。

在解压后的目录中运行：

```powershell
# 预览：不下载、不构建、不调用 CLI，也不创建目录或写入文件。
.\install.ps1 -DryRun

# 将 Host 插件包安装到 web 配置档，并将 Ruby 桥接扩展安装到 SketchUp 2024。
.\install.ps1

# 显式指定路径，支持含空格的路径。
.\install.ps1 -PluginsDir 'D:\SketchUp Plugins' `
  -DshCommand 'D:\DSH tools\dsh.cmd' -DshHome 'D:\DSH home' -Profile web
```

安装程序使用的实际 DSH CLI 命令格式如下：

```text
dsh plugin --profile web add --save-exact <absolute-package-path>
```

DSH 会安装该包，并注册其 `dsh.bundle` 配置档层。注册前，安装程序会将 tarball 包复制到 `DSH_HOME/packages/dsh-sketchup/<sha256>.tgz`，检查其内容，再使用这个持久化路径进行注册。如果输入为源码目录或包目录，则先使用 `npm pack --ignore-scripts` 打包。即使删除下载的 ZIP 和解压目录，已保存的依赖仍然可用。已有缓存条目会经过验证，且绝不会被不同内容覆盖。无需额外编辑组合配置，也不存在 `dsh cli plugin` 这一命令。选定的配置档位于 `DSH_HOME/profiles/<profile>` 下。

`install.ps1` 参数：

| 参数 | 默认值 / 作用 |
| --- | --- |
| `-SourceRoot PATH` | 默认为安装程序所在目录；用于提供 `ruby/` 和默认 Host 包。 |
| `-PluginsDir PATH` | 默认为 `SKETCHUP_PLUGINS_DIR`，未设置时使用 `%APPDATA%\SketchUp\SketchUp 2024\SketchUp\Plugins`。需要时会创建目标目录。 |
| `-SketchUpVersion YEAR` | 默认为 `2024`；仅影响默认 Plugins 路径。其他版本未经验证。 |
| `-DshCommand PATH` | 默认为从 PATH 解析到的 `dsh`；也接受显式指定的可执行文件或脚本路径。 |
| `-DshHome PATH` | 默认为 `DSH_HOME`，未设置时使用 `$HOME/.dsh`；此值会传递给 DSH 子进程。 |
| `-Profile NAME` | 默认为 `web`；配置档名称允许使用字母、数字、句点、下划线和连字符，且必须以字母或数字开头。 |
| `-PackagePath PATH` | 显式指定本地 tarball 包或包目录。未指定时，使用源码根目录中指定名称的发布 tarball 包，或使用源码根目录本身。 |
| `-SkipHost` | 仅安装 Ruby 扩展；不需要 DSH 命令。 |
| `-SkipRuby` | 仅安装 Host 插件包。 |
| `-DryRun` | 验证本地输入并打印计划，不写入文件，也不启动子进程。 |

`-SkipHost` 和 `-SkipRuby` 不能同时选择。显式指定的路径无效或不存在时，安装会失败，不会静默切换到其他安装位置。

## 从 Host 安装 Ruby 扩展

npm 包内包含 Ruby 文件和安装程序。在已安装的包目录中，或在解压后的源码目录、发布套件目录中，运行：

```powershell
.\install.ps1 -SkipHost -PluginsDir 'C:\Users\YOUR_NAME\AppData\Roaming\SketchUp\SketchUp 2024\SketchUp\Plugins'
```

此命令会同时安装根目录下的 `dsh_sketchup_bridge.rb` 加载器和 `dsh_sketchup_bridge/` 目录。重启 SketchUp 后即可注册扩展。也可以在 SketchUp 中依次选择“扩展程序管理器 → 安装扩展程序”，再选择发布的 RBZ 文件。

## 从 Ruby 扩展安装 Host

安装 RBZ 或 Ruby 文件后，在“扩展程序”菜单中选择 **Install DSH Host for SketchUp...**（为 SketchUp 安装 DSH Host）。输入 DSH 配置档、DSH 主目录、DSH 可执行文件（默认为 `dsh`），以及可选的专用工具目录。

此菜单会通过 HTTPS 从固定的 GitHub 发布版本 `v0.1.0-alpha.1` 下载 `bootstrap.ps1` 和 `SHA256SUMS`，验证引导脚本的 SHA256，然后使用经过编码、加引号的字面量参数启动独立的 PowerShell 进程。网络操作在 SketchUp UI 线程之外执行。引导脚本会下载固定发布版本的套件 ZIP，并在解压或执行前验证其 SHA256。每次重定向都会检查是否使用 HTTPS。SHA256SUMS 用于验证发布文件的传输完整性；它不是独立签名，也不能证明发布者身份。

如果 PATH 中已有 DSH 和 pnpm，引导脚本会复用它们。如果缺少工具，则仅通过 npm 将缺少的工具安装到专用安装前缀目录：

```text
<DSH_HOME>/tools/sketchup-bootstrap-dsh-0.1.5-rc.2-pnpm-11.7.0
```

缺失工具的安装包固定为 `@deepseek-ai/dsh@0.1.5-rc.2` 和 `pnpm@11.7.0`。引导脚本绝不会执行全局 npm 升级，也不会替换已有的专用安装前缀目录。如果专用安装只完成了一部分，需要重试，请通过 `-InstallDir` 指定新目录；也可以显式选择现有且可用的 DSH 可执行文件，并将其 pnpm 所在目录加入 PATH。

Ruby 菜单会传入 `-SkipRuby`，因为 Ruby 扩展已经安装。安装结果和确切的 Host 启动命令会显示在外部 PowerShell 窗口中。启动该配置档时，请保持 `DSH_HOME` 指向选定目录。对于专用目录中的安装，请在今后使用的终端中将其 `node_modules/.bin` 目录加入 PATH，以便 DSH 找到 pnpm。

也可以直接运行经过验证的引导脚本：

```powershell
.\scripts\bootstrap.ps1 -DryRun
.\scripts\bootstrap.ps1 -DshHome 'D:\DSH home' -Profile web `
  -PluginsDir 'D:\SketchUp Plugins'

# 使用本地发布文件时，仍须提供与固定 ZIP 文件名匹配的校验和条目。
.\scripts\bootstrap.ps1 -SuiteZip 'D:\Downloads\dsh-sketchup-0.1.0-alpha.1.zip' `
  -ChecksumFile 'D:\Downloads\SHA256SUMS' -DshCommand 'D:\Tools\dsh.cmd' -SkipRuby
```

引导脚本的参数包括 `-DshCommand`、`-DshHome`、`-InstallDir`、`-PluginsDir`、`-Profile`、`-SuiteZip`、`-ChecksumFile`、`-SkipRuby` 和 `-DryRun`。`-SuiteZip` 与 `-ChecksumFile` 必须一起提供。Ruby 启动器会保留下载引导脚本所用的临时目录，以便外部进程读取文件并用于错误排查；引导脚本会清理它自身用于解压套件的临时目录。

## 从源码检出目录安装

`install.ps1` 也接受源码检出目录。如果选定的包目录中没有 `lib/index.js`，安装程序会使用已有的 pnpm，先运行 `pnpm install --frozen-lockfile --ignore-scripts`，再运行 `pnpm run build`。构建错误会向上传递并中止安装。已构建的检出目录会按现状使用，并通过 `npm pack --ignore-scripts` 打包；修改源码后，请自行运行 `pnpm run build`。从源码目录或包目录安装时，需要 npm 创建这个持久化包，而不是链接到原始目录。如果源码的包清单包含 `prepare` 脚本，则会拒绝安装，因为 npm 10 即使收到 `--ignore-scripts` 也可能执行该钩子；遇到这种情况，请使用发布的 tarball 包。显式执行的 `pnpm run build` 步骤会运行检出目录中受信任的构建脚本。发布套件使用预构建的 tarball 包，不会在目标计算机上进行构建。

```powershell
.\install.ps1 -SourceRoot 'D:\dev\dsh-sketchup' -Profile web
```

## 备份、恢复与迁移

运行 DSH 包管理命令前，安装程序会将现有配置档的输入文件（`package.json`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`、`cordis.yml`、`cordis.yaml` 和 `cordis.patch.yml`）复制到相邻且名称唯一的 `.bak-...` 路径。它不会复制 `node_modules`。如果 DSH 包管理命令失败，安装程序会返回其原始退出码，并在替换 Ruby 文件前停止；此时 DSH/pnpm 可能已经更改了配置档依赖，因此恢复失败的包安装时，请检查保留下来的输入文件。

现有 Ruby 加载器和目录会在替换前移动到各自独立的 `.bak-...` 路径。Windows 使用时间戳加随机标识符命名；Bash 会以原子方式创建并占用唯一的备份目录，将旧内容放在其中的 `original` 下。已有备份绝不会被删除或覆盖。在 Windows 上，如果任一 Ruby 组件替换失败，两个组件都会回滚，并保留备份。Bash 会恢复失败的组件，并保留之前所有组件的备份，以供手动恢复。

回滚时，请关闭受影响的应用程序，将新安装的 Ruby 加载器和目录移到其他位置，再把匹配的一对备份复制回原来的名称。恢复 Host 时，请还原所需的配置档输入文件备份，并使用相同的 `DSH_HOME` 运行 `dsh plugin --profile <profile> install --frozen-lockfile`，使依赖与恢复后的配置保持一致。备份会一直保留，直到你明确决定删除它们。

此包名为 `@leolee9086/dsh-sketchup`。如果之前的 SketchUp Host 包或手动注册的 SketchUp 组合配置仍然处于启用状态，请先移除旧的 SketchUp 注册项，再启用此包；两个 Host 桥接可能会注册同一路由。请检查配置档的包清单，确认旧包的实际名称，并在适用时使用 `dsh plugin --profile <profile> remove <old-package>`。安装程序不会自动删除旧包或手动编写的组合配置。

## macOS：仅适用于已有 DSH 的环境

```bash
bash install.sh --dry-run
bash install.sh --plugins-dir "$HOME/Library/Application Support/SketchUp 2024/SketchUp/Plugins" \
  --dsh-command /path/to/dsh --dsh-home "$HOME/.dsh" --profile web
```

支持的参数包括 `--source-root`、`--plugins-dir`、`--dsh-command`、`--dsh-home`、`--profile`、`--package-path`、`--skip-host`、`--skip-ruby`、`--dry-run` 和 `--help`。源码构建和 tarball 包选择行为与 Windows 安装程序一致。macOS 的 Ruby 菜单不提供自动引导安装 Host 的功能。
