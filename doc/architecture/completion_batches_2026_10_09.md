# 集中收尾批次记录 / Completion batches

执行基线 `fb92ddb`，方案见 [中文第 11 节](optimization_plan.zh.md#remaining-work) / [English section 11](optimization_plan.en.md#remaining-work)。本报告只追加本轮证据，不改写历史全量结果。工具链：Windows、Flutter 3.41.6、Dart 3.11.4；不升级依赖，测试使用 `--no-pub`、合成数据和隔离路径。

## R1.1 收藏入口与批量提交 / Favorite entry ownership

实现 / Changes:

- 批量添加在一个 SQLite 事务内去重写入，输入值在排队前复制；保留顺序、schema 和身份。失败整批回滚，明确提交后不重放。
- 快捷删除、导出、批量添加和网络导入固定原页面、数据库、连接代数及路径；网络导入另固定源实例。删除/添加可排空已接受的有效写入，已退役目标不能写入替换后的库。
- 导入取消等待原请求，迟到业务错误仍保留；取消/不支持不按普通失败重试。真实提交后仍发布原结果，发布重试不重做导入。
- 网络删除/创建复用已有确认与输入组件；源替换使旧列表状态退役，旧结果不进入新页面。添加/转移的追更发布失败仍尝试普通视图刷新，并保留 committed 及全部发布错误。
- 打开目录固定调用时的路径，由原窗口/应用等待实际操作；隔离测试注入 opener，不调用真实文件浏览器。comic tile 和实际运行时注册的 Future/context 签名同步迁移。

验证目录 / Evidence directory:

`D:/GitHub/Agent/venera_next_task_artifacts/2026-10-09-batches-fb92ddb/`

| 日志 / Log | 范围与结果 / Scope and result |
|---|---|
| r1-favorite-entry-baseline.log | 原收藏入口新增基线：0 通过 / 12 失败；生产代码未改时复现 |
| r1-analysis-01.log | 早期 8 条诊断，后续修正调用 tear-off、导入与异步 context 检查 |
| r1-favorite-entry-targeted-01.log | 10 通过 / 10 失败；6 处测试空值断言及 4 处 SQLite DLL 环境问题，保留原日志 |
| r1-native-inputs.json | 从既有 release 复制未修改的原生依赖到新 native 目录，逐份记录源/副本 SHA-256；未重建应用 |
| r1-favorite-entry-targeted-02.log | R1 过滤集 24 通过，含真实 SQLite 回滚/去重/重开、替换源/数据库、原宿主等待 |
| r1-favorite-entry-regression-01.log | 20 通过 / 6 失败；测试路径拼写与移除仍被 MenuButton 使用的 import 导致加载/编译失败，随后修正 |
| r1-favorite-entry-regression-02.log | 8 个测试文件、207 通过；包含既有导入、确认、输入、视图和数据库回归 |
| r1-favorite-entry-consumers.log | 网络页、转移、comic_widgets 与普通确认，59 通过；与上组部分重叠，不相加为新增数 |
| r1-entry-analysis-02.log | 两处剩余样式诊断（无用 import、child 顺序），已修正 |
| r1-entry-analysis-final.log | 严格分析零诊断（26.0 秒） |
| r1-entry-format-final.log | 15 个变更 Dart 文件格式检查通过，无改写 |
| r1-entry-structure.log / r1-entry-architecture-final.log | 结构与架构门禁通过，无规则放宽 |
| r1-entry-inputs.json / r1-entry-commit.json | 基线、变更文件 SHA-256/Git blob 与提交绑定；源码副本保存在 r1-entry-inputs/ |

最终检查日志与输入清单在上述目录记录。两处样式修正不改变行为，因此不重复已通过的行为回归；严格分析和依赖门禁使用修正后的源码。未运行本组全量、覆盖率或 release 构建。

验收范围 / Acceptance: 本组为 R1 P4.4/P4.6/P7.4/P7.5、R2 P6.2 的贡献；R1 尚需源/账户及初始化资源审计。原状态仍为 **24 I / 27 P / 1 U**，不能把此组提交计为全批或原方案完成。

## R1.2 源能力与初始化审计 / Source capabilities and startup audit

执行基线 / Base: `4cdab7e`。新增 37 项真实 QuickJS 用例；原 31 项新增基线为 0 通过、31 失败。异步读取在结果借用期间生成 Dart 模型，取消等待原 Promise，成功、拒绝与解析失败均释放引用。登录、登出和网页登录成功动作改为单次执行，连接错误不再把可能已生效的动作重复三次。同步状态、标签、链接及动态分类保持同步契约，观察不支持的 Promise 并释放迟到引用；这不承诺等待脚本未返回的任意后台工作。

搜索、收藏、发现及分类复用 `runReadCodeToCompletion` 和列表解析；31 处源错误边界复用 `failureResult`，取消保留类型、原因及堆栈。移除无人调用的 parser `runReadCode`，动态分类模型只接收类型化 loader，解析和 native 引用归 parser 所有。混合发现页的 `viewMore` 由 Map 正确转换为页面目标。公开 JS 名称、参数、源 key、持久化格式和 `assets/init.js` 保持；能力证据与剩余平台边界见[中文矩阵](source_capability_matrix.zh.md) / [English matrix](source_capability_matrix.en.md)。

### 初始化与失败资源清单 / Initialization and failure resources

生产中有 5 个实际 `ensureInit` 调用点，另有方法定义和 `super` 调用；使用 Init 的类为 Appdata、ComicSourceManager、JsEngine。

| 调用点 / Caller | 顺序、所有者与失败处理 / Ordering, ownership and failure |
|---|---|
| ComicSourceManager._loadSources → JsEngine | bootstrap 先初始化 engine，再 sources；源准入与后台 init 分开登记，关闭等待已接受变更及真实后台完成。主启动不被每个源后台 init 无限延长 |
| SourceRepositories.migrate → Appdata | 在取得 AppDataOperations 许可前等待，避免持锁等待外部初始化；失败允许下一次显式迁移 |
| LocalFavoritesManager._initialize → Appdata | 打开数据库前等待，随后复核初始化 generation；局部连接失败清理与 core store 回滚保留原错误 |
| LocalManager → ComicSourceManager | 优先注入 initializeSources；默认源就绪后再次检查 disposed，再恢复下载，不能由旧初始化激活已关闭实例 |
| JsEngine._finishClose → 自身初始化 | 仅 initializing 时等待；doInit 失败直接释放资源和计算池，不通过 closeAndWait 自等待 |

启动顺序为 settings/import/source recovery → infrastructure → sources（engine 先）→ stores → finish。CoreBootstrap 失败逆序清理已登记步骤，store 初始化排空全部尝试后回滚；关闭先排空生产者，再保存/关闭存储。原失败和独立清理失败保留，已完成步骤不重放。

| 资源 / Resource | 所有者、真实结束与验证 / Owner, completion and evidence |
|---|---|
| 源注册、编辑、账户和读取 | 原 source identity/manager；替换后拒绝新调用，已接受读取等待真实 Promise，旧结果不发布到新源；source_lifecycle、source_data_admission、source_*_completion、source_capabilities |
| JS HTTP、延迟、compute、native 引用 | 原 engine/请求 scope/回调 scope；逻辑取消与真实结束分开，关闭排空登记任务并释放引用；js_engine_lifecycle、js_promise_lifecycle、源回归 |
| 启动与数据库 | CoreBootstrap/各 store；准备失败释放局部资源，核心失败完成统一回滚；core_bootstrap_*、bootstrap_source_rollback、bootstrap_core_integration |
| 阅读会话、共享图片与平台效果 | 原 ReaderSession、请求 consumer、PlatformEffectsController；退出撤销准入，保存/在途读取/释放由原宿主等待；reader_session、reading_session、shared_image_requests、platform_effects_controller |
| 收藏展示、保存及外部打开 | 原页面、路由、窗口/应用与数据库 generation；接受写入在准入时复核，提交和发布分开；R1.1 与既有收藏原宿主测试 |

上述清单是代码和本机合成集成证据。原生终止、实际外部分享消费和五平台效果由 R4 验证；跨文件存储及所有写入者的锁覆盖交给 R2，不以逻辑取消代替底层完成。

### 共性与技术规则 / Shared mechanisms and compatibility rules

对照 [repeated_workflow_matrix.zh.md](repeated_workflow_matrix.zh.md)：限流用于源更新/WebDAV 扫描；RequestScope 区分取消等待与真实结束；平台对话框按插件分别排队；SQLite 事务仅覆盖同步 SQL；WebDAV 临时连接关闭不替代书库长连接协议。收藏元数据与源读取复用已有完成/重试机制，账户动作只执行一次；未新增万能任务框架。相同机制均有实际调用者，相应重复路径已删除，进度的字节/页数/本数和不同提交语义继续由业务适配器持有。

技术规则审计确认：源 compareSemVer 保持三段数字及 hotfix/词法后缀协议；应用 release_version 保持 v 前缀、多数字段、build metadata、预发布和渠道筛选，两者不合并。文件名排序集中于 comic_file_rules，旧页序恢复继续使用 compareLegacyComicFileNames；文件名清理和归档元数据分别复用 file_system、archive_metadata。收藏 SQL 时间、评论 epoch 与界面日期格式具有不同契约，不机械统一。

### 验证与条目结论 / Validation and item decisions

| 证据 / Evidence | 结果 / Result |
|---|---|
| 旧证据目录 r1-source-baseline.log / targeted-01.log | 新增基线 0/31；首轮定向 31 通过，原日志保留 |
| 旧证据目录 r1-source-regression-01.log/json | 745 通过、无跳过；覆盖全部 comic_source 及启动、JS、网络、阅读和真实收藏源集成；命令进程 91.72 秒，测试 reporter 81 秒 |
| 旧证据目录 r1-source-analysis-01.log / analysis-02.log/json | 首轮两处样式 info 已修正；最终严格分析零诊断，命令进程 26.47 秒 |
| build/optimization_completion_2026_10_09/r1-source-* | 最终格式、结构/架构、文档检查、输入清单及提交绑定；权限环境切换后新证据写入工作区，旧产物只读 |

最终两处样式修正后不重复 745 项行为回归。12 文件格式、结构与架构门禁通过，未放宽规则。首次格式命令已完成检查但因沙箱拒绝写 Dart 用户级 telemetry session 而退出 1；原日志保留，授权后同一检查 exit 0，后缀 `-02` 为最终结果。未运行全量、覆盖率或 release 构建。R1 技术审计关闭 **P4.2、P7.4、P7.6**，原条目变为 **27 I / 24 P / 1 U**。其余 R1 条目保持 P：P4.4/P4.5/P5.7 仍需真实平台和外部消费证据，P4.6 还依赖 R2 原子性与 R4 系统生命周期，P7.2/P7.5 保留完整应用账户/错误展示及最终兼容验收。没有把这些缺项改名为后续债务来标记完成。

English: R1.2 adds 37 native QuickJS regressions and migrates source reads to real-completion consumption with deterministic reference release. Account actions execute once; synchronous hooks retain their public contract. The 745-test related-domain run and final strict analysis pass. Five initialization call sites, resource owners, shared mechanisms and distinct compatibility rules have been audited. P4.2/P7.4/P7.6 close; status is 27 I / 24 P / 1 U. Remaining storage, complete application/account/error presentation and platform evidence stays open in the original items. No new full suite, coverage or release build was run.

## R2 存储、同步与配置 / Storage, synchronization and settings

基线 / Base: `0c91ea4`。详细写入者、配置 codec、三模式/pending 和未验证边界见 [R2 审计](storage_configuration_completion_2026_10_09.md)。本批没有新生产文件，清单保持 520 文件、326 业务、166 UI、28 待审查和 241 业务入口。

- 收藏所有已迁移 CRUD、移动/复制、稍后阅读、已读和导入路径在提交后独立尝试计数/身份、追更和普通视图发布。单个回调失败不阻断后续发布；原 owner 得到 committed、原因/堆栈及其他失败，重开数据库验证实际提交，SQL 不重放。
- 阅读器容器/标识读取不再对非法旧类型直接索引或强转；编辑只修复选中 scope。图片处理使用两项现有 preference，默认脚本原样迁移；WebView proxy 使用 NetworkPreferences。
- 同步排除字段在保存、导出和导入统一解释。已有非法值可随无关编辑/恢复保留，新增非法编辑仍在内存发布与落盘前拒绝，错误由 TypeError 改为 FormatException。非法数据版本安全拒绝，旧无版本归档保留兼容；同步时间拒绝越界且不改原值。
- Core 在恢复前取得 `.app-data-owner.sqlite`，关闭全部 producer/store 且完成宿主持久化后才释放；同目录其他 Core 无法持有跨替换的旧 DB 句柄，不同目录可独立运行。独立 `.data-sync-owner.sqlite` 继续由同步服务持有。连接、isolate、独立 VM 被终止后再取得锁均验证；失败清理保留原所有权。
- 无头关闭拆为排空、解绑、持久化、关闭存储；源晚到保存仍可通知同步。排空/持久化失败时保留存储与应用锁至非零退出；独立错误报告失败不打断其余安全清理。LocalGuard 的同步写入补上 AppDataOperations admission。下载队列的完成提交仍由原队列管理，未机械加入新的同步 busy 失败。

证据目录 / Evidence: `build/optimization_completion_2026_10_09/`。已绑定的 R1 helper/日志保持只读。R2 的 native 输入复制自既有 Windows release，不重建应用、不修改插件；`r2-native-inputs.json` 记录五份 DLL 的源/副本 SHA-256，相同。

| 日志 / Log | 结果与处置 / Result and action |
|---|---|
| r2-test-publication-baseline.log / baseline-02.log | 首份夹具 ComicID 参数写反导致编译失败；修正夹具、生产未改后的真实基线为 0 通过/12 失败 |
| r2-test-publication-fixed-01.log | manager、设置持久化和稍后阅读 76 通过 |
| r2-test-configuration-01.log / configuration-ui-02.log | 首轮 49 通过、两文件缺 Switch 的 required key；修正后仅重跑两文件，23 通过 |
| r2-test-ownership-01.log | core、guard、连接/isolate/独立 VM 所有权 47 通过 |
| r2-test-headless-ownership-01.log | 24 通过；含真实 Core 在最终保存期间排除竞争者、独立 CLI 协议及失败清理 |
| r2-test-sync-configuration-01.log / -interruption.json | 继承的 native PATH 缺 ZIP DLL，导致原生用例失败和等待不到夹具 gate；中断本次进程，确认 flutter_tester 已退出，保留日志后补齐测试路径 |
| r2-test-sync-configuration-02.log | 91 通过/1 失败，暴露 Appdata 保存/导入内部剩余的排除字段强转；已修复 |
| r2-test-sync-configuration-03.log / -04.log | 28 通过/1 失败，新增导出夹具缺三份 SQLite 和源目录；补齐合成夹具，仅重跑该项通过 |
| r2-test-batch-regression-01.log/json | R2 联合集合 2,165 通过，旧的非法编辑断言和一处错误 Cookie 测试路径失败；原日志保留，不冒充整次通过 |
| r2-test-batch-delta-02.log/json | 保留拒绝新非法编辑的契约并验证旧值无关编辑，补时间范围和正确 Cookie 路径；受影响设置/Appdata/同步/Cookie 集合 279 全部通过 |
| r2-analyze-code-01 / final-02 / final-03.log | 三次对应增量后的严格分析均零诊断，最终为 final-03；未因仅格式变化重复分析 |
| r2-format-* | 29 文件格式化；最终检查发现最后一个测试夹具需格式化，修正后局部检查通过；其余格式结果复用 |
| r2-python-configuration-guard-01.log | 45 项架构 Python 测试通过；新增对图片处理与 WebView 实际消费者的反向探针 |
| r2-python-structure-* / architecture-*.log | 结构/架构门禁通过，未放宽允许边或分类 |
| r2-code-inputs-*.json / r2-inputs.json / r2-commit.json | 原始/联合/最终代码输入、变更源码副本与实际提交绑定；旧输入清单不覆盖 |

首轮联合进程实际结束后，才进行增量修复与 279 项补验。两个集合有重叠，不能相加为新增数或称为一次无失败的全量。最后增量只影响显式配置编辑的准入、同步时间读取和测试夹具；未改变的数据库/进程中断/下载/WebDAV 结果继续引用首轮，未再跑一遍 2,165 项。

原条目关闭 **P3.3、P3.4、P3.5**，两语言 canonical 表均为 **30 I / 21 P / 1 U**。P6.2 跨域依赖仍随 R3 审查；P6.3/P6.7 保留历史无日志半成品、未完成副本修复及 SAF/外部路径边界，P6.5/P6.6 保留原生 close/平台失败和总体验收。应用锁不约束第三方 SQL、旧版进程或不同应用目录共用的外部漫画路径。没有运行 R2 全量、coverage 或 release 构建；R4 保留唯一最终候选验证。

English: R2 closes typed consumer/invalid-value/gate items P3.3–P3.5. Favorites publish independent post-commit effects; the application-directory lease spans recovery, live handles, final persistence and closure. Headless teardown retains source notifications until producers drain. Save/export/import share legacy-exclusion decoding while explicit new invalid edits still fail before publication. Invalid versions and timestamps are handled safely. The 2,165-pass related run retained two actionable failures; the repaired 279-test affected delta passes. Logs distinguish product issues, test fixtures, missing native libraries and incorrect paths. No full suite, coverage or release build ran; remaining original P6/platform boundaries stay open.

## R3.1 职责、窄接口与兼容入口 / Responsibilities and explicit dependencies

基线 / Base: `e7394f8`。完整职责、原 SCC 每个文件的判定、保留入口与原范围未完成项见[唯一 R3 审计](architecture_compatibility_completion_2026_10_09.md)。清单变为 **522 文件：330 业务 / 192 UI / 0 待定，245 业务入口**；57 条允许特性边和原有业务保护保持。

LocalManager 的构造依赖只绑定一次，提供独立所有者；成功释放后才清默认实例，初始化与关闭双失败保留连接且禁止重开。LocalComicRelatedData 固定历史/收藏参与者，原三库协调验证连接代数，不能在同路径重开后继续旧删除。图片流、源仓库和漫画备份使用实例/显式请求依赖；真实恢复仍把注册交给 CBZ importer 的原生命周期。ComicList 用深复制的类型化 PageStorage 快照及请求代数隔离刷新/重挂旧任务；卡片展示不修改 tags。CBZ/详情测试直接使用真实规则和布局模型，删除重复转发。

| 日志或输入 / Evidence | 结果与适用范围 / Result and scope |
|---|---|
| r3-audit-baseline.json / current.json / final.json | 原 28 个待定文件及 46 文件 SCC；中间 41 文件环；最终恢复既定 UI 导入后为 43 个 UI/导航成员，三个原成员退出，无新成员；业务环及可达 UI 均为零 |
| r3-python-architecture-first / second.log | 首轮暴露 provider 自导入环，删除后门禁通过；保留首轮失败 |
| r3-format-first / provider-repair / analysis-repair / delta-first.log | 早期 provider 夹具残留 finally/setter 语法失败，修复后格式通过；未删除原日志 |
| r3-analyze-first.log | 缺模型 import、旧动态 state 消费及样式诊断，均已迁移/修正 |
| r3-test-targeted-first.log / targeted-first-interruption.json | 107 通过后有三个失败，新增删除夹具在持有 access 等待时请求 exclusive close 自身互等，已中断并确认测试进程退出；其他两处为 offstage finder 与遗漏客户端工厂 |
| r3-test-delta-first / source-delta-second.log | 首轮增量 13 通过/1 失败；最后一个遗漏的仓库 save 客户端工厂修正后，源页面两项（含十个源更新/仓库场景）通过 |
| r3-test-backup-injection.log | 48 通过；覆盖实例依赖互不干扰、原配置固定、传输原异常、临时文件及 WebDAV 设置消费者 |
| r3-python-architecture-unit.log / architecture-unit-authorized.log | 沙箱拒绝 Python 临时夹具访问/清理；保留失败日志，授权后 49 项通过，不计作产品失败 |
| r3-analyze-code-final / code-final-02.log | 首轮发现真实 CBZ 恢复测试仍使用旧 static 依赖；迁移该消费者后严格分析零诊断 |
| r3-test-batch-regression.log/json | **2,143 全部通过、无跳过**；覆盖完整本地库/收藏/历史/图片收藏/漫画组件/网络/启动与公共组件，以及变更源仓库、详情、阅读器和旧图片 provider 消费者。进程已实际退出 |
| r3-python-structure-final.log | 指出旧结构规则强制把已审定业务入口重定向到 UI 聚合；UI 调用者恢复原规则，仅修正业务 provider/download 与模型映射 |
| r3-python-structure-tests-final / structure-tests-behavior.log | 三项规则测试通过；最终使用合成 Dart 文件实际验证业务入口可访问、UI 内部入口与绕开模型 API 被拒绝 |
| r3-python-structure-verified / final-format.log | 最终结构检查通过，73 个变更 Dart 文件格式检查通过且无改写 |
| r3-python-architecture-final / final-02.log | 完整业务分类、UI 方向、文件环、配置和退役依赖门禁通过 |
| r3-analyze-code-final-03 / code-verified.log | 正式 UI 入口调整暴露四处重复 import，删除后最终严格分析零诊断 |
| r3-code-inputs-first / batch.json、r3-source-first / batch.patch | 初始与联合回归代码输入保留；联合清单包含 1,395 个文件 SHA-256 |
| r3-inputs.json / r3-commit.json | 最终变更源码副本、Git blob/输入/日志与实际提交绑定；提交后 helper 和原始产物只读 |

联合通过后的变更仅为正式导入入口、对应规则和文档。实际类和函数未变，行为结果继续引用，不再跑 2,143 项；最终分析/格式/结构/Python 采用调整后的输入。48 项和联合结果部分重叠，不相加为新增测试数。没有运行本组全量、coverage 或 release。

关闭 **P0.4/P2.1/P2.5/P6.2/P8.2**，中英文 canonical 表均为 **35 I / 16 P / 1 U**。**P8.1 仍为 P**：历史/收藏旧 UI 和集成夹具仍替换生产默认注册表，需要继续迁移实际装配和夹具，不能仅把 setter 改名或直接删除身份检查。P8.3 仍缺 R4 完整覆盖趋势；其余平台、真实 CLI、SDK 和性能缺项保留。

English: R3.1 completes responsibility classification and the narrow-contract/lint work, with 2,143 passing related regressions and separately recorded 48 backup/configuration tests. The final 43-member SCC is UI/navigation only. Structural rules retain UI entry restrictions and stop redirecting reviewed business entries through UI. Original failures remain classified as product, migration fixture or sandbox failures. P8.1 registry-fixture migration is explicitly unfinished; this is not completion of R3 or the original plan.

## R3.2 默认注册表与实例边界 / Default registries and instance boundaries

基线 / Base: `fe3dd89`。生产默认历史/收藏入口只读，旧夹具 200 处赋值全部移除；实际视图、阅读器、窗口关闭、追更、摘要导航与导入传入对应实例/服务。身份、路径、连接代数和宿主检查保留。独立 scope 的替换、图片收藏监听/迟到统计、摘要导航新增三项回归。完整应用导入/同步继续验证真实默认实例 close/reopen。实现与保留接口理由见[统一 R3 审计](architecture_compatibility_completion_2026_10_09.md)。

| 证据 / Evidence | 结果、失败处置与范围 / Result, failure handling and scope |
|---|---|
| r3b-registry-baseline.json / r3b-audit-final.json | 45 文件、200 处赋值 → lib/test 零赋值；524 文件、330 业务/194 UI/0 待定、245 入口；57 条边及既有业务保护不变；42 文件 UI SCC，无新增成员 |
| r3b-python-format-first / second / final.log | 首轮 79 文件，扩展后 85 文件；最终 85 文件无改写通过 |
| r3b-analyze-first / second / final.log | 19 个迁移调用/导入/初始化诊断已修复；随后两处 context lint 改为直接 mounted 检查；最终严格分析零诊断 |
| r3b-test-manager-and-runtime.log/json | 140 通过、1 失败；独立收藏夹具遗漏将 manager 传给追更预览，增量补齐 |
| r3b-test-ui-consumers.log/json | 617 通过、10 失败；导入服务与阅读器图片收藏仍取默认实例，已迁移。首轮 longStrip 的可见帧断言也失败，后续同用例在修复后的完整阅读器文件中通过，保留原记录 |
| r3b-test-import-reader-delta.log/json | 0 通过/4 加载失败；服务字段迁移时一个 import 路径拼写错误，修正后重新验证，不能计为行为通过 |
| r3b-test-import-reader-delta-02.log/json | 226 全部通过；完整阅读器退出文件、PDF、真实恢复门面、收藏 manager 和独立 scope，原相关失败均消失 |
| r3b-complement-files.json / r3b-python-domain-complement.log/json | 按先前输入补充 84 文件，881 通过/1 失败；覆盖剩余修改及详情、导入、同步、图片收藏与新历史导航；唯一失败为新统计夹具缺 Material 宿主 |
| r3b-test-binding-fixture-final.log/json | 补齐 Scaffold 后该新夹具单项通过；原 881 项未重复执行 |
| r3b-python-rules-unit-first.log | 49 项架构 Python 测试通过；新增禁止可写缓存字段/setter/赋值的探针，保留只读 getter、比较与诊断 |
| r3b-python-architecture-final / structure-final.log | 最终架构、结构门禁通过；未修改结构规则，既有三项结构规则行为测试继续引用 R3.1 相同脚本证据 |
| r3b-code-inputs-ui-first.json / r3b-source-ui-first.patch | 首轮界面回归输入与差异留存，后续改动以最终变更快照为准 |
| r3b-inputs.json / r3b-inputs/ / r3b-commit.json | 最终源码/文档与所有本组日志、helper 绑定实际提交；绑定后只读 |

各集合存在重叠，不相加为新增总数，不把有失败的运行描述为整次通过。Flutter 测试均等待实际进程退出再继续；最后的生产变更只涉及明确的图片收藏替换/摘要导航，相关文件在补充集合中通过，最后夹具修复只改测试 Material 宿主。没有执行本组全量、coverage 或 release。

关闭 **P8.1**，两语言 canonical 表为 **36 I / 15 P / 1 U**。R3 技术收尾完成；P8.3 的完整覆盖趋势归 R4。原有完整 CLI、声明 SDK、五平台、外部消费与固定设备性能仍未验收，不据此标记原方案完成。

English: R3.2 removes all writable default-registry substitutions through real injected owners and preserves replacement/admission checks. Related runs, original failures and repaired deltas remain separate evidence. The 84-file complement reuses unchanged earlier results and covers remaining consumers; its sole new fixture failure passes after adding a Material host. Strict analysis, formatting and structure/architecture checks pass. P8.1 closes; R3 technical cleanup is complete. No full suite, coverage or release build ran in this group.

## 剩余验收 / Remaining acceptance

R1/R2 本轮代码收尾与 R3 技术清理均已提交；R4 已完成一次本地全量与覆盖率记录、Windows/Android Release 构建和完整产物核验。全量的原超时及原样复测分别保留。声明 SDK、完整真实 CLI、五平台安装/启动、六类固定设备性能和原条目的跨批边界缺少结果时继续保留未完成，不能用合成单测替代。

## R4 本地候选验收 / Local candidate acceptance (2026-10-10)

生产候选 `5b338ad` 保持不变，CHANGELOG 在全量和构建前冻结。唯一全量＋coverage 为 4,951 通过、2 项既有跳过和 1 项源初始化 5 秒超时；保持源码/断言/超时的单项复测通过，失败日志保留，没有再次全量。LCOV 40,198/50,542（79.53%），严格分析、1,031 文件格式、结构/架构、116 项 Python（3 项既有跳过）、版本/Git 依赖和独立审查工具通过。

P8.3 关闭，原 52 项为 **37 I / 14 P / 1 U**。524 文件、330 业务、194 UI、0 待定、245 入口、57 条特性边与 42 个 UI/导航环成员保持。Windows/Android Release 均成功，完整 64 文件 Windows 包与四个 APK 核验通过，原 90 份产物未变。独立构建输入、准备失败/网络中断、最终产物与合成签名边界，以及全部 15 个剩余原条目统一见[R4 报告](final_acceptance_2026_10_09.md)。P8.5 依“有未完成验收时不标记整项完成”保持 P。

English: R4 preserves the production candidate and records one full run (4,951 passes, 2 existing skips, 1 timeout) plus the unchanged isolated passing case. Fresh coverage is 79.53%; listed static gates pass. Windows/Android release builds and artifact checks pass; all 90 original outputs remain unchanged. P8.3 closes, leaving 37 I / 14 P / 1 U. The single report retains original failures, build inputs/artifacts and remaining SDK/CLI/platform/performance/historical-recovery acceptance. P8.5 is not closed by documentation alone.
