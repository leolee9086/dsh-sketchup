# CEF 兼容说明

SketchUp 2024 内嵌 Chromium 支持的 JavaScript API 可能落后于当前 Harness 客户端。为此，内嵌窗口会在应用模块执行前加载 `core-js/stable`。垫片编译为 Chromium 80 能解析的语法，并嵌入 Host 构建产物，不从 CDN 下载，也不会修改 Node 进程中的全局对象。普通浏览器标签页会在执行垫片前直接退出这段初始化流程。

覆盖的标准 API 包括 Iterator 及同步迭代器辅助方法、Set 运算、返回新数组的非原地操作、Object／Map 分组、`Promise.withResolvers`、`RegExp.escape`、字符串格式修复和类型化数组的新方法。`AbortSignal.any` 属于浏览器 API，仍由单独的垫片提供。`window.__DSH_CEF_COMPAT__` 记录被监测 API 在加载前后的缺失情况，不包含会话或模型数据。

## 验证方法

运行 `pnpm test` 和 `pnpm run build`。测试在隔离的 JavaScript 环境中模拟 API 缺失，检查迭代器提前关闭、Promise 完成、集合运算、原数组不被修改，以及普通浏览器不被注入等行为。

构建成功并不代表运行中的 Host 已更新。需要重启 DSH、刷新 SketchUp 内嵌窗口，再确认应用加载完成。本项目已在 SketchUp 2024 中实际验证 Iterator 修复后的完整聊天界面。

## 适用范围与限制

JavaScript 垫片无法升级 CEF 的语法解析器、CSS 布局、图形能力、编解码器或需要特殊权限的浏览器 API。Web Worker 使用独立的全局环境，若其中缺少 API，需要为 Worker 单独设计兼容方案。新增 Harness 模块后，仍应进行 API 特性检查和真实内嵌窗口测试。

## 第三方许可

core-js 的版权归 Denis Pushkarev 及其贡献者所有，采用 MIT 许可证。未修改的许可证原文随项目保存在 `THIRD-PARTY/core-js-LICENSE`。源码地址：[zloirock/core-js](https://github.com/zloirock/core-js)。
