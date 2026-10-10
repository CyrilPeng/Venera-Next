# R2 存储与配置收尾 / Storage and configuration completion

基线 / Base: `0c91ea4`。本文件记录 R2 的代码边界审查；测试命令、失败记录及提交绑定统一见 [completion_batches_2026_10_09.md](completion_batches_2026_10_09.md)。使用 Windows、Flutter 3.41.6 / Dart 3.11.4、合成数据和隔离目录；不连接个人库或启动真实应用。

## 写入者、快照与目录所有权 / Writers, snapshots and directory ownership

应用快照包含 `appdata.json`、`history.db`（含图片收藏）、`local_favorite.db`、`cookie.db` 及漫画源文件。`local.db`、本地图片、`downloading_tasks.json`、缓存以及锁和恢复日志不属于此快照。每个数据库使用 SQLite 快照；跨文件一致性由调用方的 `AppDataOperations.run` 排空写入后保证，SQLite 单库事务本身不提供跨文件事务。

| 写入者 / Writer | 同进程准入与真实结束 / Admission and completion | 进程间边界 / Cross-process boundary |
|---|---|---|
| Appdata 配置、搜索历史、implicit 状态及导入 / Settings, search, implicit state and import | `AppDataOperations.access/run` 后进入原写入队列；暂存 rename 和全部独立写入完成才返回，导入保留 checkpoint | Core 启动恢复前取得应用目录锁；最终持久化及资源关闭后释放 |
| 历史与图片收藏 / History and image favorites | 注入的 `_operations` 控制同步/异步写入；父操作等待 isolate 写入；快照先等待已接受写入 | 同一 Core 生命周期锁覆盖原连接及导入重开的连接 |
| 收藏 CRUD、排序、稍后阅读、追更 / Favorites | `_mutate` 先全局准入再本地队列，复核原连接 generation/path；SQL 事务之后独立发布计数、身份、追更及普通视图 | 同上；协调删除/导入持有相同应用准入，提交后不重放 SQL |
| Cookie / Cookies | 同步桥使用 `accessSync`，异步桥持有应用准入；导入在独占期间更换同一应用连接 | 同上；关闭仍释放导入后替换的 Cookie 连接 |
| 漫画源数据、安装及事务恢复 / Source data and installation | 已有 preparation/access、SourceDataStorage 和事务 journal；恢复早于读取，manager/engine 排空实际 Promise | Core 在恢复前加锁，在 producer/store 全部关闭后解锁 |
| 本地导入、页序、删除、搬迁与恢复 / Local import, order, deletion, relocation and recovery | `runImport/runExclusive` 持有应用 access；同步 `write` 本轮补 `accessSync`，失效 Zone 和无归属写入不能越过独占操作 | 同目录协作 Core 被排除；外部配置的共享漫画目录和 SAF 提供者仍有独立边界 |
| 下载提交与任务文件 / Download commits and task files | DownloadQueue 持有自己的目录分配、提交和退出生命周期；存储独占拒绝活动/暂停队列并等待未完工作。TaskStore 自有串行落盘 | 属于应用所有权，但不属于应用同步快照；不能在完成下载时临时加同步 busy 拒绝而丢弃提交 |
| 同步 marker、内容、导入和上传日志 / Sync journals | DataSyncController 持有 `.data-sync-owner.sqlite`；日志恢复、真实传输和最终持久化完成后释放 | 应用锁与同步锁是两个独立文件，允许原进程同时持有；其他同目录 Core 在任何数据库读取前被拒绝 |

`.app-data-owner.sqlite` 是版本 1 的独立 SQLite 排他事务，复用现有所有权实现。锁文件不删除、不打包进快照，不依赖超时、PID 或启动清扫判断。采用整个 Core 生命周期的所有权，避免另一个进程在快照替换后继续使用早先打开的数据库句柄。不同应用数据目录独立运行。该协议约束本版本的协作 Core，不声称控制第三方直接 SQL、旧版本进程或两个应用目录共同指向的外部漫画目录。

正常关闭先排空生产者，再完成同步/持久化，最后关闭存储和释放应用锁。无头模式仍在源排空期间保留数据变更绑定；独立的绑定释放和同步收尾均尝试，生产者/持久化排空失败则保留存储和锁至非零退出。Core 启动失败仅在全部回滚成功后释放锁；失败清理仍可能持有原生写入者时不让第二个 Core 进入。

The application lease spans startup recovery, live database handles, final persistence and store closure. Per-operation locking alone would leave another process using stale handles after replacement. Independent sync ownership remains separate. Failed producer/persistence drains retain the application lease until process exit. This is a cooperative-core contract, not a lock on arbitrary external writers or shared SAF providers.

## 配置消费端与持久化协议 / Typed consumers and persisted formats

| 范围 / Scope | 当前边界与兼容决定 / Boundary and compatibility |
|---|---|
| 阅读全局/设备/漫画 / Reader scopes | ReaderPreferences、ReaderSettings 与 ReaderPreferenceStore 解释值；非法外层或记录容器读为未启用，读操作不改原始值。明确编辑只修复所选记录，其他记录和未知字段保留；模式决策统一用 readerSettings |
| 设备标识 / Device identity | 非字符串标识不再在读取时强转；明确设备编辑或原有启动标识初始化才生成 UUID。持久化 key、漫画 identity 和设备 scope 格式保持 |
| 图片处理 / Image processing | `ImageProcessingPreferences.enabled/script` 供实际 provider 和编辑器使用；默认 JS 内容原样迁移，开关与 Reset 只修改选中字段 |
| 网络、外观、发现、关键词、收藏和应用行为 / Application preferences | 复用现有不可变 preference/codec；WebView 代理改用 NetworkPreferences。已迁移消费端受字面量 key 门禁保护；存储适配器仍能用规范 `.key` 恢复原值 |
| 同步连接、模式、间隔和排除字段 / Sync configuration | SyncConfiguration/SyncPreferenceStore 统一解释；错误类型排除字段在读取时视为空文本，原值保留。保存、导出和导入使用相同解释，避免编辑器能打开而真实落盘崩溃 |
| 数据版本 / Data version | 非负整数参与比较和递增；非法非空版本明确拒绝同步且不替换数据，不默默归零。旧的无版本归档仍保留原导入路径，普通手动旧版本导入不变 |
| 同步时间 / Sync timestamps | 显示时间和上次尝试时间拒绝错误类型、负数及超出 DateTime 范围的值，分别按未同步/未尝试读取；不改写原始状态 |
| WebDAV 备份和在线书库 / Backup and online library | 已有 BackupConfig 和 WebDavLibrarySettings codec，保留原配置、排除规则和注入边界，不再另造同义抽象 |
| 搜索捷径、源仓库、来源和迁移标志 / Metadata | SearchShortcut.fromJson、源配置/仓库事务 codec 拥有原始键；这些是记录编解码与迁移，不是未迁移的普通界面设置读取。旧来源字段继续用于迁移，不机械删除 |
| implicit 页面状态和恢复记录 / Page state and recovery records | 页面筛选/排序由对应页面状态解析，sync operation 保留原始值供版本化解码。读取未知/损坏恢复证据不能将其清空冒充成功 |

新增非法排除字段的显式设置编辑仍在内存发布和落盘前拒绝，错误改为明确的 FormatException。已有非法值随无关编辑、导出和导入原样保留；恢复 checkpoint 继续按原始证据执行。两者具有不同的准入语义，不能为支持旧值而接受新的非法编辑。

Reader and application consumers use typed boundaries; codec/transaction layers retain raw records to preserve unknown fields. Existing invalid exclusions use one interpretation throughout save/export/import and remain unchanged; an explicit edit introducing a malformed filter still fails before publication or persistence, now with a FormatException. Invalid versions fail safely; legacy unversioned archives remain supported. Timestamp readers also reject values outside DateTime's range without repairing storage. Format, defaults, exclusion keys and public JS are not redesigned.

## 三种同步模式与 pending / Modes and pending

| 模式 / Mode | 触发和重启 / Trigger and restart | pending / 冲突 |
|---|---|---|
| manual | 不启动自动传输；显式命令仍先恢复日志并取得所有权 | 本地变更记录 pending；未取得服务所有权的关闭不写默认状态 |
| realtime | 原启动/恢复及变更触发；重复 start 不重复订阅，stop 保留变更观察，dispose 才解绑 | 真实内容基线复核后决定方向；完成旧操作时若有新 generation，继续保留本地 pending |
| scheduled | 注入时钟/计时器按原间隔运行；重启补逾期，时钟倒退不无限推迟 | 待上传本地编辑优先；下载等待期间内容变化拒绝覆盖，已提交操作先完成原后续步骤 |

三模式共用版本化 operation、receipt 与内容证据；下载自身通知通过 publication scope 隔离，独立本地编辑仍可见。失败或不匹配证据保守保留 pending/恢复要求。取消等真实传输与清理结束；退出等待配置、恢复 I/O、在途传输及最终状态写入。原 controller、内容/恢复、WebDAV 和实际 Appdata 集成回归作为联合证据，不以重复实现模式逻辑增加测试数量。

All modes retain the existing scheduling, generation and receipt semantics. Download publication suppresses only changes caused by that import; independent local edits remain observable. Recovery finishes committed follow-up work against original evidence, never by replaying an already confirmed write.

## 仍保留的验收边界 / Remaining acceptance boundaries

R2 补齐同目录协作进程锁、配置消费者和收藏提交后发布；真实平台终止/断电、SAF/外部路径竞态、共享外部漫画目录、历史无日志半成品和未完成副本修复没有由本次合成回归证明。旧数据恢复必须继续保守处理未知提交，不能通过删除旧记录或重新执行写入掩盖缺口。P6 的跨域窄接口交 R3，完整应用、CLI、五平台与六类性能仍按 R4 原矩阵验收。

R2 does not turn synthetic tests into evidence for power loss, real SAF providers, external path replacement or incomplete historical copies. Cross-domain interfaces continue in R3; full application/CLI, platform and fixed-device performance acceptance remains in R4.
