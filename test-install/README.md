# 安装程序回归检查

请从 Windows 上的源码检出目录运行。除下述真实 npm 打包操作外，这些检查仅将模拟工具和模拟包安装到新建的临时目录中；`npm-shim-tests.ps1` 还会调用本地真实的 npm 可执行文件，为临时测试样例打包，但不会从包注册表安装软件。检查不会调用真实的 DSH CLI，不会在实际使用的配置档中注册任何内容，也不会修改已安装的 SketchUp 扩展。临时测试样例会被保留，并打印其路径以供检查。请在子进程中运行每个脚本，不要通过点源方式将其加载到当前 shell。

```powershell
# PowerShell 7 下的安装流程，包括源码打包与构建、备份和回滚。
pwsh -NoProfile -File test-install/installer-tests.ps1

# 使用原生 Windows PowerShell 5.1 执行同一组安装程序测试用例。
pwsh -NoProfile -File test-install/installer-tests.ps1 -PowerShellCommand powershell.exe

# 缺少 DSH/pnpm 的分支：隔离的 PATH、模拟的 Node/npm 和专用安装前缀目录。
pwsh -NoProfile -File test-install/bootstrap-private-tests.ps1

# 实际调用 Windows npm.cmd 查询 --version 并进行本地打包；拒绝包含 prepare 的源码。
pwsh -NoProfile -File test-install/npm-shim-tests.ps1
pwsh -NoProfile -File test-install/npm-shim-tests.ps1 -PowerShellCommand powershell.exe

# 需要 Ruby 3.2 或更高版本，且 PATH 中可通过 pwsh 调用 PowerShell。
ruby test-install/ruby-installer-tests.rb

# 已有 DSH 环境下的 shell 安装流程；已使用 Windows 上的 Git Bash 测试。
& 'C:\Program Files\Git\bin\bash.exe' test-install/shell-installer-tests.sh
```

可通过 `PWSH_COMMAND` 覆盖 Ruby 参数转义测试使用的可执行文件。Windows 正式安装流程仍会启动系统自带的 Windows PowerShell 可执行文件。

Windows 测试套件检查：无写入的试运行、含空格的显式路径、精确的 CLI 参数和 DSH_HOME、按 SHA256 寻址的持久化包缓存、唯一备份、加载器被锁定导致失败时两个 Ruby 组件的恢复、源码构建失败的传递、依赖生命周期脚本的禁用、预构建 tarball 包的选择、经验证的 ZIP 引导安装、解压目录清理后的持久可用性、校验和不匹配时的拒绝行为，以及原生退出码 29/37/43。

专用工具测试套件检查：固定版本的 DSH/pnpm 包参数、不使用全局 npm 标志、拒绝覆盖已有的专用安装前缀目录、原生 npm 退出码 51，以及 Node 22.13 最低版本要求。Node 和 npm 均为模拟实现，不会下载任何包。

Ruby 测试套件检查菜单注册的幂等性、校验和条目匹配、不匹配及重复的情况，以及对 HTTP URL 的拒绝行为。它还会通过生成的编码 PowerShell 启动器执行一个无害脚本，以验证单引号、空格、与号和 `$()` 字符串仍作为字面量参数值传递。

Bash 测试套件检查源码安装和发布包安装、持久化缓存、唯一备份、试运行行为、精确的 CLI 参数、DSH_HOME，以及原生失败状态码 31 的传递。它不验证 macOS 上的 SketchUp 行为。可使用 `bash -n install.sh` 额外进行仅检查语法的验证。

这些模拟检查不涵盖 GitHub 在线下载的可用性，也不涵盖在全新计算机上实际通过 npm 安装工具的过程。发布时必须验证发布资产名称和 SHA256SUMS。
