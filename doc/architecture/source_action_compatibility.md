# 源操作结果与归档读取 / Source action and archive results

本批相对 `3ac99ff`，复用已有的同步结果消费/释放机制，新增单次执行的完成入口，并接入九类源写操作。归档两项读取继续采用只读重试，但等待原顶层 Promise 并在转换后释放引用。公开 JS 方法、参数、源格式、归档模型和页面布局保持。

## 写操作与结果归属

`JsEngine.runCodeToCompletion` 等待一次调用的顶层结果，将原生返回图借给同步消费者，在返回 Dart 数据或错误前释放图中的引用。它复用已有读取完成桥的释放主体，包括原始异常/堆栈和清理错误的组合，不复制一套引用遍历算法。`SourceParserContext` 在调用前及消费时校验原运行时和源身份；相同 key 的新源不承接旧回调。

这个入口本身不加入只读网络重试，也不在已接受操作完成后追加取消转换。已有 HTTP 桥仍继承环境中的 RequestScope，外层调用者仍可报告取消；不能据此宣称远端副作用可撤销或全局 exactly-once。评论/收藏中原有的“登录过期后重新登录，再调用一次”规则保持，重新登录失败仍不重放操作。

| 能力 | 返回规则 |
|---|---|
| 漫画点赞、评分 | 完成后返回 true，丢弃未使用的 JS 值并释放其引用。 |
| 普通/章节发评论 | 完成后返回 true，保留原登录过期恢复。 |
| 评论投票、点赞 | num 继续 toInt，其他正常返回值继续按 0；完成转换后释放原值。 |
| 收藏添加/删除 | 完成后返回 true，保留原登录判断/恢复；旧 favId 参数仍不传给 JS。 |
| 收藏夹添加、删除 | 完成后返回 true；没有新增登录或网络重试。 |

同步抛出的对象与 Promise 拒绝值均保留为结构化原因及原堆栈，其中原生回调已释放，不再允许调用。忽略的结果图也必须释放；仅检查 debugOwnedReferenceCount 不足以证明旧 runCode 返回的原始引用无泄漏，因此回归还执行真实原生关闭检查。

此批处理顶层 Promise 和同步返回/异常图。任意嵌套且未被消费的 Promise、脚本自行发起且未返回的后台任务，以及运行时强制结束时的完整外部副作用归属仍需单独审查。账户登录/退出既有的读取完成与重试契约未在本批修改。

## 归档读取与错误保留

`getArchives` 和 `getDownloadUrl` 在现有读取完成桥内同步调用原归一化器；归档模型只留下 Dart 字符串。列表顺序、重复 ID、空字段、URL 空字符串和空白均沿用原源协议。页面侧的链接辅助函数继续 trim，并拒绝空链接；源解析器不替页面改变 URL。

只读瞬时错误仍最多重试两次。取消会传递到现有请求作用域，但返回的完成信号仍等待原顶层 Promise。迟到成功不发布数据，原 RequestCancelled 保留为 cancelled；迟到真实拒绝保留原错误并释放其中的引用，不再启动重试。源回调退休后同样拒绝迟到数据。

详情归档辅助函数现在转交完整错误 Res，保留 FailureDetails 的身份、原因、堆栈和取消分类。直接抛出的错误也保存 cause/stack，直接抛出的 RequestCancelled 标为 cancelled。普通字符串错误信息、成功列表回退、链接修剪和空链接提示保持。未改全局 Res.fromException 分类，也未改归档下载 UI 或下载队列。

## 证据与剩余范围

新增 41 项回归：九类写操作及重登录/参数/数值/退休/取消共 25 项，原生归档读取 13 项，上层错误传递 3 项。旧代码上，写操作 20 项失败；归档与辅助函数 11 项失败。原生关闭明确报告 raw JS 引用泄漏，错误返回中的回调仍可执行；取消回归观察到完成过早，辅助函数回归观察到原因与堆栈丢失。修复后定向 44 项和扩展 678 项通过，后者包含全部漫画源/详情测试以及相邻 JS 资源、Cookie、Promise 和真实事务中断回归。

六个修改的业务文件均保持在已有保护中；没有新增公开业务文件或扩大特性依赖。清单保持 506 文件、322 业务、151 UI、33 待审查、237 业务入口，原有 57 条特性边和 46 文件 SCC 保持。六项接回 UI 的探针均被拒绝。脚本表达式、评论/收藏重登录主体、读取重试循环和共享释放主体通过旧新文本核对；数据模型、归一化器、JS assets、源管理器、源编辑页面及全部页面布局未改。

最终冻结源码、全量结果、覆盖率、Windows 构建和提交绑定以执行记录及 `source-action-artifact-hashes.json` 为准。原 52 项保持 24 I / 27 P / 1 U。源编辑生产调用者、其余配置/接口/生命周期/存储/JS/兼容、完整 CLI、声明 Flutter 3.41.4、五平台及固定设备性能仍需验收。

## English

The new single-execution completion entry borrows an owned native result for synchronous conversion, then releases result/error references using the existing release implementation. Nine mutation adapters use it without generic network retries or an added post-completion cancellation conversion. Existing ambient HTTP cancellation and comment/favorite login-expired recovery remain. Arguments, ignored-result success, numeric truncation/non-numeric zero and source/runtime identity checks are preserved.

Archive adapters keep their read-only retry policy and original normalizers, join the original top-level Promise after cancellation, reject late data and release result/error references. Ordering, duplicate/empty fields and raw URL semantics remain; upper helpers still trim links and reject empties, while now retaining structured failures, causes, stacks and cancellation. No global Res classification or UI changes were made.

There are 41 new regressions. Old code fails 20 action and 11 archive/helper cases, including native close reporting raw reference leaks. Targeted44 and extended678 pass after the change. Six existing business files retain all protections; inventory506/322 business/151 UI/33 pending/237 entries,57 feature edges and46-file SCC remain. Arbitrary descendant Promises, unreturned tasks, account retry contracts, source editor callers and full domain/platform/performance acceptance remain open.
