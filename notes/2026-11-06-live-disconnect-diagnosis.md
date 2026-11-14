# 医院 SketchUp 实例间歇掉线诊断

- 时间：2026-11-06 02:21:44 +08:00。
- 位置：仓库 D:/dev/dsh-sketchup；SketchUp 2024 PID 18840；实例 sketchup-e37c07cc-4ad5-41ed-b601-d1f15af8b486；Host 127.0.0.1:56488。
- 意图：哥哥指出连接不稳定，排查图层统计期间发生的掉线；保留继续完成图层检查的上下文。
- 结果：医院实例在 02:14 前后多次断开；另一个空模型实例 cda88184 持续在线。02:16 左右恢复，02:19～02:21 连续 Ruby 读取和统计文件保存成功。尚未捕获实际关闭原因，不能声称已经修复。

## 已查证

- 源码和已安装 websocket_client.rb 内容一致；当前 TCP 写入/握手超时 5 秒、读取超时 90 秒。
- Host 每 30 秒发送 JSON ping；Host 没有因未收到 pong 主动断开的逻辑。
- Ruby 发送队列上限 256 帧/16 MiB；队列满主动关闭连接。写线程异常也会关闭，但原实现吞掉错误细节。
- Ruby main.rb 的 log 仅 puts，SketchUp 临时日志没有对应 DSH/WebSocket 行。现存日志不足以归因。
- 截图的 ruby_execute=false 是断开后 @host_caps 被清空造成的状态；Host rubyExecuteEnabled 仍为 true。
- 不要因为 history=200 就认定历史导致断线：这是本地环形缓冲容量，发送队列独立。最后读取发送队列 frames=0、bytes=0，writer=sleep。

## 已装入的临时诊断（仅进程内）

通过 sketchup_ruby 在 PID18840 里 prepend DSHSketchupBridge::SessionTransportTrace：

- ManagerLog#log 记录连接日志。
- Transport#write_all 记录写入异常类别、消息和字节数。
- Transport#send_frame 记录入队异常类别、消息、opcode、字节数。
- Transport#read_frame 记录读异常、EOF 和对端 Close code/reason。
- Mutex 保护的最近 60 条元数据；不收集载荷正文；不改传输行为或模型。
- 获取：DSHSketchupBridge::SessionTransportTrace.events。
- 02:21:44 读取为空，表示装入诊断后未出现新故障。没有重启进程，没有改 profile。

## 图层检查已完成

长扫描在 02:14:29 实际执行完成，结果传回时断线。Ruby 全局 $zhi_layer_audit 保留结果，已成功取回并保存：

- 项目/建模/图层检查/图层重名统计_20261106.json。
- 项目/建模/图层检查/图层重名清单_20261106.csv。

统计：205 个原生标签，无完全同名；822 个“图层_”组件节点；去除末尾 #数字后 134 组名称重复；CAD 外参前缀归一后 41 组标签变体。

完全重名且在同一父级的只有一组：05_二层天花方案图.dwg 下两个“图层_IRC-分缝线”，实体 1463266 和 2703773。截图箭头“图层_DT-03-中线#2”归一后在三个导入图纸中出现：03_装饰平面、05_天花方案、08_综合点位。

## 已捕获故障并完成源码修复

- 时间：2026-11-06 02:32～02:46 +08:00。
- 位置：同一医院实例，以及仓库 ruby/dsh_sketchup_bridge/websocket_client.rb、main.rb。
- 意图：修复哥哥再次指出的桥接不稳定，恢复重名组件清理前的可靠传输。
- 证据：临时诊断在 02:27:24 和 02:29:32 记录 write_error，Timeout::Error / WebSocket write timed out，待写帧仅 18 字节（JSON pong 加 WebSocket 帧头及掩码）。之后多次出现对端 4001 / hello timeout。此前的 822 个组件盘点实际于 02:30:27 完成，结果保存在 $zhi_layer_cleanup_inventory，不能重放长扫描。
- 缺陷：wait_io 在检查内核套接字就绪状态前先判断墙钟 deadline；SketchUp 原生操作延迟 Ruby 线程调度时，即使套接字已经可读写也直接抛超时。hello 由独立写线程发送，再增加一次调度等待。
- 修改：wait_io 先零等待查询就绪状态，无进展才执行原 deadline；TCP 连接改为 Socket.tcp 的 connect_timeout；HTTP 升级读取使用非阻塞读和同一就绪/超时逻辑，去掉异步 Timeout 包装；connect(initial_frame:) 在连接线程完成校验后直接发送 hello，再启动写线程；Manager 使用该入口。
- 测试：新增 transport_scheduling_test.rb 四项真实 TCP 回归。修改前 4 项中 3 项失败；修改后完整 Ruby 套件 48 项、0 失败。系统禁止文件符号链接的既有 fixture 仍跳过，目录联接测试通过。git diff --check 通过。

## 当前部署边界

- 运行中的 SketchUp 仍是旧代码，修复尚未安装，不能称现场修复完成。
- Host 的 allowPluginWrite=false、allowPluginLoad=false，allowRubyExecute=true。开发者规则要求插件写入/加载必须开启相应 Host 开关并 confirm=true，不能用 Ruby eval/load 或文件复制绕过。
- 本轮没有 plugin_manager / cordis_inspect_query 等配置工具；Playwright 打开现有 Harness 地址 127.0.0.1:56488 返回 401。未读取凭据，未改 profile 文件。
- 下一步需要从 Harness 正式配置入口启用插件写入与加载，再以 sketchup_write_plugin 更新两个已审阅源文件，使用官方加载工具加载，然后让同一个 Manager 停止并重新启动工作线程。保留 instanceId、模型与当前编辑状态。
- 加载后读取方法位置与连接状态，执行小批量盘点读取，确认不再误报超时。代码测试不能替代现场验证。

## 配置面板补齐（2026-11-06）

- 时间：03:02 开始核查；10:11:48 +08:00 完成构建与检查（期间哥哥明确要求继续）。
- 位置：D:/dev/dsh-sketchup；当前 Harness 127.0.0.1:56488。
- 意图：哥哥指出没有暴露配置面板，无法操作之前要求开启的两个开关；先补齐实际可操作入口。
- 已证实：运行时 dsh-settings 0.2.2-rc.1 只投影 volatile 字段，且未提供自动生成页面；插件原来只有普通 Config 字段、没有 Client。当前配置入口是 plugins.row.config，key 为 @leolee9086/dsh-sketchup#bridge-sketchup。
- 实现：src/client.js 原生 Client 注册配置页，三个权限开关暂存后显式保存，通过页面提供的 form.mutate 携带 revision；拒绝/冲突保留草稿并显示错误。中文、英文文案，包元数据与原创 SVG 图标、client/locale/icon 导出已补齐。
- Host：三个字段改为 volatile 引用，apply 通过 getter 读当前值。server 在每次工具分发前、每次心跳时检查权限变化，使用已有 hello.ok 同步至 Ruby；保持连接、实例 ID 与运行中任务。Host 新增插件写入/加载即时拒绝检查。
- 测试：67 项 Host 测试全部通过（包括真实 WebSocket 的权限变化顺序和撤销拒绝），pnpm run build、Client 语法检查、显示资源存在性及 git diff --check 均通过。两个后台任务 pwsh-d83c397e166c4f35、pwsh-1290431d78654675 已收取，exit 0。
- 现场限制：plugin_manager/cordis_inspect 工具仍不存在；Playwright 唯一页面仍为 401 Unauthorized。当前会话无法触发正式插件重新组合。未改 profile、未用 CLI 管理 Desktop 插件、未读取凭据。需要哥哥在现有“插件”页将 SketchUp 桥接关闭再开启，触发已链接包的 Host/Client 重新加载，再刷新页面。
- 未验证：当前 GUI 内页面实际呈现与保存；未开启任何权限；Ruby 传输修复仍未部署；模型清理仍未执行。不能把源码与构建完成报告为现场已生效。

## 尚未执行的模型清理

哥哥明确要求：名称忽略末尾 #数字后重名的“图层_…”组件，每类只留一份。尚未发生删除。原生标签无完全重名，不能把 CAD 外参前缀归一当作额外删除规则。保留策略已说明：优先已建三维内容，其次当前可见实例；清单和备份完成后再执行。已建烟感和喷淋层必须保留。外观由哥哥在回路验证，不追加预览。

