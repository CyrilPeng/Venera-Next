# 初始化等待与失败资源审计

2026-10-03，检查当前工作区。范围：lib 中所有 ensureInit 调用、所有 Init 混入者，以及 createCoreBootstrap 的直接启动步骤。此清单不等于全应用生命周期已验收。

## 等待边界

| 等待方 | 前置启动所有者 | 失败与剩余边界 |
|---|---|---|
| SourceRepositories.migrate → appdata.ensureInit | CoreBootstrap.settings 先完成 appdata.init | 本阶段让并发迁移共享同一 Future；保存失败恢复迁移标记和本次创建的列表，保留期间替换的列表，后续调用可重试。 |
| ComicSourceManager.doInit → JsEngine.ensureInit | bootstrap_core.sources 先 await JsEngine.init | 引擎失败不会进入源管理器/仓储步骤；直接调用源管理器仍要求调用者先启动引擎，ensureInit 本身不隐式启动。 |
| LocalManager._initialize → ComicSourceManager.ensureInit | CoreBootstrap.sources 完成后才开始 stores | 生产依赖顺序明确；测试/独立装配可注入 initializeSources。打开库后多处检查 disposed，异常分支释放数据库。 |
| LocalFavoritesManager._initialize → appdata.ensureInit | settings 先于 stores；只在 App.isInitialized 时等待 | 连接代数避免关闭期间发布，未发布和已发布失败分别释放数据库。设置默认值写入失败后的内存/磁盘一致性仍需专项审查。 |

lib 中仅 Appdata、JsEngine、ComicSourceManager 使用 Init。Init.ensureInit 只等待；init 共享一次尝试，失败保持失败，retryInit 才开启新尝试。不要把 CoreBootstrap.start 缓存失败误认为资源自动回滚或服务自动重试。

## 资源所有权与下一步

| 所有者/步骤 | 已见机制 | 明确未完成项 |
|---|---|---|
| CoreBootstrap | 串行 environment/settings/infrastructure/sources/stores/finish；源码失败不启动等待中的仓储 | stores 已通过 initializeCoreStores 等待所有尝试结束，失败逆序释放本地/收藏/历史库，包含失败库的部分资源；清理失败聚合并保留初始异常。成功仓储及 finish 中打开的缓存在后续启动失败时由 CoreBootstrap 逆序回收；跨阶段基础服务/源引擎释放和正常退出仍未统一装配。旧自动同步标记迁移现等待 writeImplicitData，保存失败恢复本次标记并触发启动回滚；其他未等待保存的消费端仍需逐项迁移。 |
| Appdata | 写入队列，文件替换，Init 状态机 | 设置加载和设备 ID 写入失败后的完整重试矩阵；无文件句柄常驻不代表内存状态原子。 |
| JsEngine | 初始化失败/销毁共用资源释放，关闭 QJS/port、拥有的 Dio 和临时客户端；resetDio 优雅关闭旧客户端；等待脚本后检查销毁；旧实例不清新单例；已销毁实例拒绝 init/retry | 客户端优雅关闭允许原有请求结束；完整 JS Promise/回调取消矩阵、原生平台行为与核心整体资源释放仍需验收。 |
| ComicSourceManager | 单源错误仍隔离；整批目录/运行时提供者失败移除本次 Dart 注册，并用保留的解析器回滚句柄还原 JS 注册和释放回调；整批成功后才提交句柄并启动后台 init | 全量 reload 已保留旧 Dart 对象和 JS 注册表，整批失败/已有文件损坏恢复旧状态，成功才释放旧回调；新增坏脚本继续跳过，删除文件正常移除。仓库监听器与后台 init 退出仍需补齐；加载期间仍使用暂存的全局注册表，未提供并发读取快照隔离；提供者外部副作用不在回滚范围。 |
| CookieJarSql/SingleInstanceCookieJar | 构造拥有连接并在建表失败时释放；移除可重复打开连接的 init 入口；dispose 幂等，单例仅清除自身引用；显式目录下并发创建共享实例，损坏库失败后可修复重试 | 默认平台目录解析期间的取消/跨目录切换仍需结合核心生命周期验收；当前保持单例首个路径语义，不将目录参数视作切库请求。 |
| HistoryManager | 共享初始化 Future；所属连接直接初始化历史/图片收藏表，过期清理和已接受写入完成后发布 ready；失败释放对应连接，close 幂等且连接代数拒绝旧结果 | 仓储同组失败现由启动装配先等待已接受写入再 close；跨阶段及正常退出仍需统一。close 不取消已接受的独立连接写入，完整退出仍需先 waitForAsyncWrites。 |
| LocalFavoritesManager | 共享初始化/连接代数/closeAndWait；失败关闭对应库 | 仓储同组失败现由启动装配调用 closeAndWait；跨阶段失败及正常退出仍需统一。 |
| LocalManager | 初始化失败释放数据库；源等待后检查 disposed | 下载恢复、存储保留与所有后台任务的完整退出矩阵仍需验收。 |
| CacheManager | 显式拥有构造工厂返回的数据库，建表失败释放；dispose 共享关闭 Future，排空已接受操作后关闭并仅清除自身单例；关闭期间新工作被拒绝 | finish 中取得缓存后登记失败释放入口，后续启动失败先排空缓存再关闭仓储；正常退出尚未统一装配。扫描失败继续记录后允许队列工作，保持现有语义。 |
| OpenCC | 共享初始化 Future，失败清除尝试允许重试；完整解码/解析后发布不可变表，重复成功调用复用；CRLF 与 Unicode 码点解析 | 本项目维持单字映射、重复键末项优先，不扩展为词组语义转换；实机大词表性能仍随总体性能验收。 |
| 翻译 / SAF / Rhttp | 核心必需与可选步骤已区分 | 原生工作线程/网络运行时释放需查插件实际协议，不能凭 API 名推断。 |
| headless | finally 释放 sync，清除源保存回调，并等待 flushPersistence；失败输出错误且退出码为 1 | 仍依赖 exit 结束其他核心资源；不等于完整 Flutter 服务组装可重复启动/释放，真实 CLI 平台结果仍待收集。 |

验证范围：现有 core_bootstrap_test 覆盖依赖顺序、共享启动和源失败阻止仓储；本阶段新增迁移实际文件失败/并发/重试/配置替换测试。以上未完成项保留在 P4.2/P4.4 与 P8 总体验收，不以测试总数替代。

仓储启动回滚专项：core_store_startup_test 覆盖真实 SQLite 迟到成功后逆序释放、同步初始化失败、清理错误聚合与成功保留资源。该协议仅覆盖启动时的 stores 组；本地下载恢复为暂停快照，不能将此清理路径用于已开始下载的正常退出。

后续阶段回滚专项：core_bootstrap_failure_test 覆盖真实 SQLite/缓存队列排空、finish 失败逆序关闭、失败组不重复清理、清理异常保留初始原因及成功保留资源。回滚异常统一为 CoreStartupRollbackFailure；启动仍缓存失败，未提供跨实例自动重试协议。

隐式保存边界：Appdata.writeImplicitData 现返回队列中的实际保存 Future；启动通过 migrateLegacyAutoSync 等待落盘并保留未知字段，失败恢复 absent/null 标记且不覆盖期间改成另一值的偏好。同步控制器的保存回调现支持 FutureOr，configure 提交/回滚会等待隐式与普通设置的全部保存尝试；普通上传/下载现等待首次与结束状态保存，结束保存失败恢复本次清除的 pending；onDataChanged 后台保存错误会被记录和发布，完整后台保存排空/退出协议仍未完成。并发独立启动实例的迁移隔离仍未承诺。

同步任务持久化：首次保存失败阻止传输；结束保存期间任务仍占有队列，失败返回错误并恢复原 pending。网络失败与结束保存失败同时发生时保留两者消息。dispose 期间已接受文件写入并不取消；flushPersistence 现刷新最新状态并等待接受中的保存；窗口关闭及无头命令退出已调用。flushPersistence 本身不停止调度；窗口现通过 prepareForExit 冻结新传输/配置，等待已接受的配置、上传和下载后刷新，取消关闭时按代数解除限制。跨源后台任务与全应用退出顺序仍待统一。

退出保存刷新：控制器跟踪异步保存 Future，flushPersistence 先写最新状态再排空期间接收的保存，可在 dispose 后调用并重试历史失败。窗口无上传时也等待刷新，失败释放下载/导入准备状态并阻止正常退出；无头命令在正常核心启动后的 finally 等待刷新，失败改为错误退出。

同步退出准备：prepareForExit 共享一轮准备 Future，暂停自动调度、拒绝新的公开传输与配置，等待已接受配置（包括它的内部初始传输）及活动/排队任务后刷新。失败自动解除，成功返回带代数保护的幂等恢复回调；窗口持有回调并在解绑/取消关闭时释放。该范围不涵盖其他域的后台任务。


## P4：基础设施阶段失败回收 Cookie 数据库（2026-10-04）

- initializeCoreInfrastructure 显式拥有本阶段新建的 Cookie 数据库；先构造服务尝试列表，通过 Future.sync 将同步抛错纳入并行等待，全部尝试结束后才回滚。借用已有实例时不关闭它；成功后资源继续交给应用使用。
- 新增 3 项真实 SQLite 回归，覆盖同步失败与迟到服务共同结束后清理、Cookie 写入重开保留、借用实例失败保留和成功保留。实际无组件核心启动及 Cookie 生命周期专项合计 8 项通过。
- 该清理仅处理 infrastructure 阶段失败；sources/stores/finish 后续失败及正常退出的 Cookie、JS 和原生服务统一释放仍待完成。用户原有修改保留。


## 源队列与插件释放协议复核（2026-10-04）

- 首次源加载现进入 _mutationTail，与其他注册表变更串行；source_initialization_queue_test 使用真实 QuickJS 验证依赖等待期间重载不会抢先替换注册表。
- 锁定依赖 flutter_saf fe182cdf 的 SAFTaskWorker.dispose 仅关闭响应端口并立即 kill isolate；没有排空 _completerMap 或完成待处理 Future，也不清除 instance。init 使用 late isolate/sendPort，不能将 dispose 不加区分用于部分初始化失败或活跃任务退出。
- 锁定依赖 flutter_qjs 8feae95d 的 wrapper.dart 将 Promise 转为只由 resolve/reject 回调完成的 Dart Completer；engine.close 释放 context/runtime，但没有显式完成这些 Completer。项目 runCode 直接返回 evaluate 结果，_initializeSource 的 15 秒 timeout 只是停止等待，未取消原 Promise。需在项目引擎边界落实可观察的销毁终态，不能把 timeout 当成后台工作排空。
- rhttp 0.15.1 的 Rhttp.init 委托 RustLib.init；生成桥提供 RustLib.dispose（注释标为 app 停止时自动处理）。此接口不是逐客户端优雅退出的证明，仍需按真实调用与活动请求核验。
- 上述为本机锁定依赖源码审查，不替代 Android SAF 或五平台运行验收；尚未改动依赖缓存。


## P4/P7：JS Promise 的销毁终态（2026-10-04）

- runCode 与 JsCallbackScope.retain 的异步返回统一跟踪；引擎资源释放及作用域关闭完成尚未结束的等待并返回 StateError，父作用域释放覆盖子作用域。同步返回仍原样返回，已完成 Future 不被改写；维持原生桥对未观察 Promise 错误的处理方式，显式 await 仍收到失败。
- 关闭后的迟到成功/失败不再次完成结果；原引擎仍存活时递归释放迟到结果携带的 JS 引用，并核对引擎身份，避免通过替换后的 runtime 释放旧引用。作用域关闭不影响兄弟作用域，也不声称取消底层 JS/网络副作用。
- 新增 3 项真实 QuickJS 测试，覆盖永不完成的脚本及子作用域回调、作用域关闭后的迟到函数结果/拒绝、兄弟调用成功、同步/异步正常结果和原始错误。源事务与引擎生命周期专项共 20 项通过。
- 本阶段提供等待方可观察的终态；直接使用未保留 JSInvokable、源管理器后台 init 的退出装配、SAF worker 与完整应用资源释放仍待验收。用户原有修改未纳入提交。


## P4/P8：JS 计算池实例依赖与关闭所有权（2026-10-04）

- JSPool.create 注入脚本加载器和引擎工厂，生产默认仍使用共享池；删除 debugLoadJsInit、debugCreateEngine、resetForTesting 和 debugInstanceCount，测试各自拥有并关闭实例。
- close 共享同一 Future，在调用开始时冻结 init/execute，等待已有初始化及所有引擎关闭；代数检查阻止关闭前等待初始化的任务在重开后提交。同步关闭异常不跳过其他引擎，所有尝试结束才报告错误；本轮成功关闭后允许显式或按需重开。
- 引擎构造先暂存，全部成功后发布；部分失败回收已创建引擎，并保留启动及清理错误。失败清理句柄保留在池内，init/execute 拒绝重开，只有 close 重试成功后恢复。成功关闭的引擎不重复关闭。初轮专项捕获部分失败句柄过早发布破坏共享 init 的问题，现延后到整组回收完成才发布失败资源。
- 专项 6 项通过，包含 3 项关闭/回滚回归和真实 Windows QuickJS 计算池执行、关闭及重开。原 full 日志运行期间调整了代码，不能作为最终状态验收；retry-targeted 是修复前失败记录，verified-targeted 为最终专项结果。
- 该协议没有统一接入核心退出，也未证明无限计算、isolate 意外退出或所有原生平台终止行为；这些与源后台 init、SAF 一并继续验收。用户原有修改未提交。


## P4/P7：JS 计算 isolate 异步结果与任务释放（2026-10-04）

- 工作线程等待 JS 函数的异步结果后再发送数据，同步抛错、异步拒绝和发送异常均返回任务失败，finally 释放函数及结果原生引用。列表/映射递归校验原生 JS 引用，直接及嵌套函数结果不可跨 isolate 传递；参数采用同样检查，普通数据和 ArrayBuffer 字节结果继续支持。
- 参数发送失败移除对应任务并更新 idle，避免 close 永久等待未发送工作；close 共享 Future，已接受任务结束后才释放端口与 isolate。保存并等待 spawn Future，关闭期间迟到的句柄由统一关闭路径回收，不再提前 kill 正在排空任务的引擎。
- 增加 5 项真实 Windows 原生回归，池专项合计 11 项通过：延迟异步结果与关闭排空；同步/异步/无效函数/原生引用错误后继续工作；原生参数引用仍属原引擎；无法发送参数后排空；启动完成前关闭。初轮原生函数返回用例使测试提前结束，增加传输边界后通过；随后修正字节测试为插件支持的 ArrayBuffer 输入，保留 Uint8Array 既有映射语义。
- 日志 js-worker-targeted/native-transfer/final-targeted 保留中间结果，verified-targeted 才是最终专项。意外 isolate 退出、无限计算和全应用 shutdown 仍待验收；关闭等待 spawn 句柄不等于已观察操作系统线程终止事件。用户原有修改未提交。


## P4：JS 计算线程异常退出与关闭确认（2026-10-04）

- IsolateJsEngine 在 spawn 时注册 onError/onExit 并明确 errorsAreFatal；未捕获错误保留 RemoteError 的消息和远端堆栈，异常退出完成尚未结束的启动/任务等待。正常关闭保持响应端口可用，发出 kill 后等待真实退出事件才释放端口，迟到 spawn 句柄不再重新发布已退出实例。
- Worker 启动参数改为命名 record，构造可注入遵循 SendPort/Task/TaskResult 协议的入口。新增 4 项真实 Dart isolate 回归，无需伪造消息：握手前退出、启动未捕获异常、关闭排空期间主动退出及未捕获异常。与池和原生 QuickJS 专项合计 15 项通过。
- 关闭依旧等待已接受工作完成后 kill；无限计算不会被这个协议自动打断。此阶段确认 Dart isolate 的退出事件，尚未实现 worker 内正常退出时显式释放全部 native runtime 的停止消息，也未接入全应用 shutdown；这些继续按 P4/P8 验收。用户原有修改未提交。


## P4：JS 计算线程正常停止与原生资源释放（2026-10-04）

- 正常 close 排空已接受任务后等待传输握手，发送 JsWorkerStop；worker 在 finally 中显式释放 JsEngine，再关闭已创建的子 JSPool，关闭任务端口、发送 JsWorkerStopped 清理结果并退出。关闭同时等待清理确认和真实退出；清理失败或无确认退出不会报告成功。
- 传输就绪与任务接纳等待分离，启动期间 close 可以拒绝任务并仍取得控制端口。未捕获错误/异常 worker 继续强制结束；异步自动关闭的错误被记录，显式 close 仍返回原失败。清理失败保持失败结果，不宣称可重新执行已退出 worker 的清理。
- 新增 3 项真实 Dart isolate 协议回归，分别阻塞清理与退出并验证成功、清理失败和缺失确认；与异常退出、池及真实 Windows QuickJS 专项合计 18 项通过。初轮测试缺少 StreamIterator 导入，修正后通过；该轮 full 已主动停止，最终证据使用 verified-targeted/final 日志。
- 此阶段未给无限计算或不响应协议的 worker 引入自动超时强杀，也未将核心退出、源后台任务和 SAF 统一装配。默认 worker 的正常退出显式调用资源释放；跨平台实机和整体性能仍按原方案验收。用户原有修改未提交。


## P4：JS 释放异常隔离与启动失败清理顺序（2026-10-04）

- 引擎释放按快照尝试所有作用域、runtime、端口、当前及临时 HTTP 客户端；作用域同样逐项释放子作用域和回调。单项抛错不跳过后续资源，JsResourceReleaseFailure 保留每项资源名、异常和堆栈。所有权引用先清空，重复 dispose 不重复释放已尝试句柄；不声称失败的底层释放已成功或可重试。
- 初始化异常触发清理时，如果清理也失败，JsEngineInitializationFailure 保留初始原因和清理错误，并沿用初始堆栈。worker 捕获的启动/运行失败先保存，完成 finally 清理并发送结果后才通知父线程，防止受控错误过早触发父线程 kill 打断清理；真正未捕获异常仍走强制路径。
- 新增 4 项回归：作用域多个释放失败仍处理末项、前一作用域失败不阻止后续作用域、真实 QuickJS 初始化失败与 HTTP 客户端释放失败同时保留、默认原生 worker 启动失败后结束清理与退出。相关生命周期专项 25 项通过。
- 全应用启动/退出装配、源管理器后台任务和 SAF 仍未统一完成；资源释放异常可观察不等于已证明所有 native 资源无泄漏。用户原有修改未纳入提交。


## P4：源管理器关闭与跨阶段启动回滚（2026-10-04）

- ComicSourceManager.dispose 立即解除仓库监听和通知器，closeAndWait 共享释放 Future；新 init/ensureInit/变更及直接 add/remove 被拒绝，已接受的排队操作继续完成。跟踪原始初始化 Promise 的终态，15 秒等待超时不等于排空；未完成 Promise 会继续阻塞关闭，不默认强杀或丢弃副作用。
- 排空后删除所属 JS 源注册并逐项释放回调，收集释放失败；清空查询、分类、收藏及图片加载绑定后释放自身单例，新实例可重新装配，旧关闭调用不会清除新实例。该管理器不拥有 JS 引擎，宿主必须先关闭源管理器再释放引擎。
- 核心启动登记源绑定、JS 引擎/计算池与源管理器清理句柄，后续 sources/stores/finish 失败时逆序清理；成功 infrastructure 阶段新建的 Cookie 数据库也登记跨阶段回滚，借用既有 Cookie 实例不取得关闭所有权。此装配延续单个应用启动所有者，未承诺多个独立 CoreBootstrap 并发持有同一运行时。
- 新增 4 项真实 Windows 回归：源后台 init 排空/监听解绑/实例替换；实际等待超时后仍等原 Promise；已接受安装完成后关闭；损坏 local.db 触发后续阶段失败并确认源、引擎和 Cookie 释放。联合源事务、依赖等待、Cookie 基础设施和核心启动专项共 21 项通过。首轮发现 ready 状态仍可通过 init，现同时在 init/ensureInit 拒绝关闭实例。
- 仍待完成正常窗口/无头命令的全应用退出装配、源自行启动的独立定时器或未返回任务、SAF/Rhttp 等基础设施生命周期及跨平台验收。用户原有修改未提交。

## 无头关闭与持久化所有权（2026-10-04）

CoreBootstrap 增加可等待关闭，缓存结果并汇总资源错误；失败启动不重复清理。源管理器等实际 init、源文件保存和异步通知，包含移除/替换的旧源。WebDAV 传输与缓存已登记释放；Cookie 关闭覆盖本次数据路径的导入替换连接，保留不同路径实例。

无头 finally 在核心关闭后解绑和刷新同步状态；设置加载失败不写默认值。正常窗口还需追更、WebDAV、阅读请求与原生基础设施排空，close API 的存在不等于完整平台退出已验收。

追更退出增量（2026-10-04）：任务执行终态与进度流分离；全局拥有 job/直接更新的退出限制，后台服务拥有自己的调度、检查及观察订阅。窗口先等待这一准备再处理存储和同步，解绑恢复不会重新启动已 disposed 的运行时。RequestScope 的取消竞速仅隔离追更数据库副作用，不是源/原生请求全面终止证明。

WebDAV 退出增量（2026-10-04）：源拥有注入的缓存、传输、同步器和快照；dispose 同步冻结，closeAndWait 等全部业务及元数据原始 Rhttp 请求后关闭缓存。同步器和快照仅排空各自工作，不释放调用方 SQLite/传输。核心使用可等待入口，窗口在追更之后持有可恢复准备；准备中的解绑等 WebDAV 完结再开放追更。BufferedRHttpAdapter 专用于库的目录/元数据，图片字节下载仍属于图片/阅读所有者。全局 Rhttp/SAF、重挂载实例与不可逆桌面关闭继续审计。

窗口输入增量（2026-10-04）：WindowFrame 拥有内容/退出焦点、活动指针和局部导航准入；只有关闭守卫通过后才冻结，失败排空迟到保存后恢复焦点并通知业务绑定释放准备。SyncWindowBinding 不再拥有同步弹窗，窗口统一显示等待与强退操作。主函数仍未保留并关闭 CoreBootstrap；在阅读及其他写入所有者全面排空前，不将这层输入拦截视作安全关闭核心的充分条件。

平台事件增量（2026-10-04）：EventSubscription 使用显式串行队列和处理完成信号；取消订阅与业务完成分别等待，迟到异常交给原错误接收方。可恢复准备清除队列、使既有处理的代次失效，持续监听并丢弃准备期间事件，避免恢复后重放。InteractiveBindings 拥有所属链接/分享订阅、定时器及每个心跳调用的完成信号；最终释放等待所有调用并保留各订阅取消异常。窗口先准备平台事件，再准备其他服务；解绑期间先等待当前准备结束，再释放之前的限制。

Windows 原生 monitorUIThread 在最后一次 heartBeat 超过 5 秒后直接退出进程，因此可恢复准备必须继续心跳；本次未关闭原生监控线程，也未接入不可逆核心退出。最终宿主关闭与重挂载仍需明确原生监控协议和资源归属，不能将 Dart 调用排空当作原生线程已释放。Android 链接/分享由注入流验证，实机 EventChannel 取消和其他平台仍待验收。

Windows 监控后续增量（2026-10-04）：全局 monitorUIThread 已由 FlutterWindow 拥有的 HeartbeatMonitor 替代，startHeartbeat 返回代次编号，heartBeat/stopHeartbeat 均校验编号；Stop 唤醒并等待实际线程结束，OnDestroy 在引擎释放前关闭，析构可重复清理。WindowsHeartbeat 拥有挂载注册与调用，绑定最终释放排空后显式停止；旧注册迟到也会回收，旧停止不影响新挂载。原生 CTest 2/2 与 Windows release 构建通过；桌面不可逆核心退出仍未接入，完整宿主和非 Windows 原生生命周期继续待办。

共享图片源流增量（2026-10-04）：SharedRequestStream 的 isClosed 表示接收关闭，done 表示源流实际取消/自然结束；最后一个订阅者等待源流 finally，其他订阅者保持独立。当前 ImageDownloader 映射仍在接收关闭时移除，尚未全局保留退休请求；RequestScope.run 会提前结束源配置等待，这一层之后的原 Promise 与原生传输不能由 stream.done 推断为已排空。

图片配置后续增量（2026-10-04）：_resolveComicImageConfig 现在保留原 resolver Future，取消后等待并释放未交付结果；源流 finally 因而也覆盖这一等待。discardImageLoadingConfig 按身份遍历引用，处理别名/循环并收集全部 free 失败。只覆盖返回的 resolver Future 和未交付配置；正常配置、解析失败值与 resolver 内部未返回任务、原生传输及全局退休请求仍需单独审计。
