# 源设置回调兼容边界 / Source setting callback compatibility

基线 `9e58a608`。公开 JS API、回调名称/参数、源 key、持久化格式、事务协议、`assets/init.js`、译文和依赖均未改变。本批修改 JS 回调完成边界、源上下文的可选消费接线和设置按钮；未改变其他源能力、更新/删除导航或旧执行/读取重试逻辑。

| 场景 / Scenario | 行为 / Behavior |
|---|---|
| 普通 `callback(arguments)` | 仍是真正 Dart Function，保留同步返回、Future 和作用域即时逻辑取消。 |
| 显式 `consume` / Action completion | 在原引擎登记一次调用，直接调用捕获的原 JS function，保留参数对象身份；不序列化或重新求值。 |
| 同步返回或顶层 Promise 完成 | 同步借用消费结果，随后释放同步可达的共享/循环/Map 键引用；消费函数不可保留这些借用对象。 |
| throw / reject | 释放拒绝引用图并保留原失败与堆栈；多个清理错误汇总而不掩盖主异常，原引擎关闭也保留释放失败。 |
| 快照作用域销毁 | 普通调用仍立即逻辑取消；已接受的显式消费调用等待实际顶层结果，不能用逻辑取消假称排空。 |
| 原生运行时终止 | 尚未完成的调用以 `JsDisposedError` 结束；不把强制终止当作脚本成功。同步 JS/Dart 重入关闭先等待调用栈及函数租约释放。 |
| 无原生引擎的 Dart 回调 | 关闭后仍等待原 Dart Future；完成后释放结果，并按原所有者状态返回失败。 |
| 源/管理器/宿主或路由变化 | 拒绝新准入和迟到提示；已接受调用由原应用/窗口等待。按 key 的替换不能接管旧调用。 |
| 主题重建 | 设置快照可重新生成；稳定 setting key 保留运行中按钮的 loading，原调用仍等待完成。 |
| 普通 Dart 函数设置 | fallback 单次调用并等待，释放未使用的同步/异步返回和拒绝引用；不自动重试。 |
| 窄屏/大字号 | 标题与按钮上下排列，按钮文字可换行且至少 48px；普通字号保留原 32px ListTile 按钮布局，加载时仍有语义名称。 |

只等待本次调用的**顶层 Promise**。任意嵌套 Promise 和没有返回给调用者的后台任务不在此契约内，也不保证任意脚本会自行结束。原有 HTTP 取消、存储准入及源关闭仍由各自所有者管理；本批没有增加通用任务队列、只读重试或副作用自动重放。未声明远端副作用可撤销或全局 exactly-once。

最终基线对照为 `source-setting-callback-before-native-final`：8 项中 7 失败、1 通过。四种结果/拒绝图泄漏使用真实 QuickJS 引用观测；另外三项覆盖原应用/窗口过早关闭及冻结按钮。主题重建在旧版已通过。早期对照的编译、原生端口事件泵与定位错误仅用于夹具诊断。

新增 29 项行为回归涵盖原始/owned callback、不同引擎、兄弟作用域、同步重入释放、参数身份、清理错误、普通 Dart fallback、生产页面源替换/路由/宿主/关闭、静态设置、大字号和语义。定向 35 项及扩展 784 项通过。375×740 深色、812×375 浅色使用提取的前后组件：两组普通字号像素一致，两组 2 倍字号目视核查；为中文显示统一注入的字体仅在外部截图夹具中使用。未启动真实应用访问个人数据。

未完成范围包括其余 metadata/search/category/favorites 读取图、account 重试与取消、更新检查服务/结果配对及删除导航，以及原 52 项的跨域接口、配置、生命周期、存储恢复、兼容退出、完整 CLI、声明 Flutter 3.41.4、五平台和固定设备性能验收。当前 Flutter 3.41.6 / Dart 3.11.4 的测试、组件截图和 Windows 构建不替代这些证据。

Ordinary callbacks keep their previous function and logical-cancellation contract. Explicit consumption calls the original function once, joins its top-level completion, synchronously consumes borrowed results, and releases returned/rejected reference graphs while preserving primary and cleanup failures. Snapshot cancellation does not prove native completion; runtime termination is an error. Original application/window/source ownership spans accepted calls, and route/owner changes suppress new admission and late presentation. Descendant Promises and unreturned work remain outside the contract. Public source protocols and the broader acceptance limits above remain unchanged.
