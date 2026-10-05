# 架构优化逐项验收清单

审计基点：`99e607d`，2026-10-02。工作区包含原有用户修改；检查结果针对该工作区，不能当作仅 HEAD 的验证。原方案范围完整保留。本文件是执行索引，不是完成声明。

状态：I = 当前已核对到实现证据（仍受总体验收约束）；P = 部分实现；O = 代码明确显示未完成；U = 缺少足够验证。I 不代表整个阶段完成。证据列的短文件名位于本目录或 `.github/scripts/`，其余为仓库相对路径。

进度口径（2026-10-05）：下表共 52 个原方案子项，23 项 I、28 项 P、1 项 U；已有实现证据占 44.2%，不是整体工作量或最终验收完成率。部分项已包含多次独立提交，不能视为尚未开始，也不能主观折算为完成百分比。当前主要缺口为残余业务/UI 与配置边界、桌面核心及图片/原生任务完整关闭、阅读壳和真实平台行为、数据/源失败矩阵、兼容层退出，以及完整 CLI、五平台和固定设备性能验收。原方案的 8 条总体验收尚未全部通过。

## 本轮增量：普通收藏准入与调用方等待（2026-10-05）

普通收藏修改、异步读取及身份索引刷新接入全局准入和局部队列；初始化等待索引，关闭等待已接纳工作。多目标移动与追更详情/时间使用完整事务，文件夹设置保存被等待；旧网络结果和导入 receipt 不跨连接代次写入或发布。页面等待/错误反馈、排序保存和阅读器收藏更新的退出归属已补充；本地存储任务统一先全局准入再进入局部所有权。新增 16 项回归，扩展组合 210 项通过，最终验证见最新执行记录。其余 appdata/源/跨库写入、持久 revision/内容基线和整体平台/CLI/性能验收继续待办；52 项状态与 103 个受控入口均不变。

最终冻结全量 **2674 项通过、2 项既有跳过**，LCOV **62.98%**；严格分析、格式、Python、静态门禁和 Windows release 全部通过，打包 CHANGELOG/JS 初始化脚本匹配源码。中断全量的延时取消问题已修复，最终验证顺序及产物哈希见执行记录。

## 前一单元：Cookie 准入与请求归属（2026-10-05）

Cookie SQL、过期清理和连接生命周期均接入准入，同步 JS API 在替换期间明确拒绝并保留既有同步返回约定；Dio 和网页验证保存等待准入。请求绑定原连接，旧响应不能跨同路径重开污染新会话，未换库的导出后响应正常保存，真实 SQL 失败保留原因/堆栈。新增 24 项权限、SQLite/Dio、QuickJS 与页面生命周期回归；精确验证结果见最新执行记录。普通收藏、appdata、源和跨库写入、持久 dirty/revision/内容基线及其他总体验收仍待完成；受控入口 103、52 项状态均不变。

最终生产源码全量 **2658 项通过、2 项既有跳过**，LCOV **63.06%**；新增 QuickJS 测试补齐原生库不可用跳过条件后，本机 4 项实际执行通过，生产源码未改。严格分析、格式、Python、静态门禁与 Windows release 均通过，打包 CHANGELOG/JS 初始化脚本与源码一致；完整验证顺序见最新执行记录。

## 前一单元：图片收藏准入（2026-10-05）

图片收藏的查询、切换、删除和统计接入历史数据库准入与局部队列；在准入后读取当前记录执行修改，缓存清理失败保留已提交状态。统计 worker 使用固定路径的只读连接，不再初始化全应用，替换/退出排空等待其关闭。页面适配异步结果、查询错误/重试、忙碌状态与路由身份，阅读器收藏接入已有 ImageWork。新增 15 项回归，具体冻结验证见最新执行记录；受控业务入口为 103。其他写入者、dirty/revision/有效内容基线与其余总体验收未完成，52 项状态不变。

全量 **2634 项通过、2 项既有跳过**，LCOV **62.86%**。全量后仅修正公开入口引用和格式，随后 127 项相关专项、最终格式后的 18 项数据专项、严格分析、所有静态门禁及 Windows release 通过。精确验证顺序、日志和工具链边界见最新执行记录。

## 前一单元：历史写入准入（2026-10-05）

历史写入先全局准入再入局部队列，独占导入/导出排空旧写入并阻止新写入越过；连接归属在准入时捕获，旧元数据拒绝跨代次。内部初始化/排空可重入，通知及提交回调发起的新工作独立排队；导入重开与外部排队初始化共用一次真实工作，避免等待环。联合专项 50 项通过，冻结全量结果及工具链边界见最新执行记录。图片收藏、其他存储与源写入、跨库操作和通知边界仍待接入，持久 dirty/revision/内容基线尚未完成，原 52 项状态不变。

最终全量 **2619 项通过、2 项既有跳过**，LCOV **62.42%（24,207/38,781）**，严格分析零诊断；格式、diff、Python 74 项/3 项既有跳过、结构/架构/依赖/版本门禁及 Windows release 通过。日志、产物哈希和工具链边界见最新执行记录。

## 前一单元：上传持久恢复（2026-10-05）

原清单状态不变。上传 journal、稳定快照、条件创建和完整内容核验已接入；v3 intent 按原 endpoint 恢复，确认后只补留存/固定时间/实际连接关闭/本地清理，持久清 marker 后才 ack。快照与导出暂存目录归 App.dataPath 下本次操作所有。保留全局留存策略，强 ETag 缺失明确留下待清理任务，异内容不覆盖，已确认后被删除的远端文件不重建。22 项真实进程恢复、20 项执行器（含真实 SQLite 持久写失败）、3 项生产组件 HTTP 组合及 38 项远端协议专项分别通过；集合和后续全量不简单相加。全量冻结结果及平台边界见最新执行记录。

全部写入者屏障、内容基线与 dirty 持久窗口、并发导入编辑冲突、其余生命周期和最终 CLI/平台/性能验收仍未完成；业务入口受控数量增至 102。

本轮最终验证：**2605 项 Windows Flutter 测试通过、2 项既有宿主跳过；LCOV 62.35%（24,139/38,714），严格分析零诊断，25 个 Dart 文件格式及 diff、Python 74 项/3 项既有跳过、结构/架构（102 个入口）/依赖/版本门禁及 Windows release 全部通过。** 工具链边界、日志与产物哈希见最新执行记录。

## 前一单元：导入持久恢复（2026-10-05）

原清单状态不变。独立导入 journal 与启动前恢复已接入，v2 同步下载依据匹配终态记录恢复收尾，先持久清 marker 再确认 receipt。真实进程终止、导入器/控制器重建及 bootstrap 分别验证；详见最新执行记录。全部参与者的写入屏障、持久内容基线、远端上传对账与其余总体验收尚未完成。

本轮最终验证：**2500 项 Windows Flutter 测试通过、2 项既有宿主跳过，LCOV 61.69%（23,450/38,011），严格分析零诊断，23 个 Dart 文件格式及 diff、Python 74 项/3 项既有跳过、结构/架构（99 个入口）/Git 依赖/版本门禁及 Windows release 全部通过。** 日志、产物哈希和工具链边界见最新执行记录。

## 前一单元：同步提交状态验证（2026-10-05）

本轮从 `0d552c9` 开始。严格分析零诊断，Python 74 项/3 项既有跳过，结构、架构（97 个业务入口）、版本与 Git 依赖门禁通过，未扩大例外；持久化专项 20 项通过。**最终全量 2429 项通过、2 项既有宿主跳过，LCOV 22,772/37,284 行（61.08%），25 个 Dart 文件格式及 diff 检查、Windows release 构建通过。** 日志继续位于仓库外 `../venera_next_task_artifacts/2026-10-04-01a104a6/`，详见最新执行记录；旧单元构建不作为本轮验证。

本轮范围：同步三态保留已应用与不确定结果，导入等待 `saveData` 并在替换前持久化精确 checkpoint，独立执行各资源回滚。控制器先保存 intent，再执行传输；同进程失败只补收尾，按 generation 清旧 pending 并继续实时上传新编辑。配置仅在 `notApplied` 时回滚，提交与回滚两类保存的四路错误完整保留。重建或损坏 marker 阻止重复同步；远端文件名/哈希 journal 与自动跨进程 reconciliation 尚未实现。数据落盘到 dirty 标记持久化的窗口、导入期间真实本地编辑冲突、备份导入提交/删除失败、其余生命周期以及完整 CLI、五平台和固定设备性能仍待处理，52 项状态不变。

上一单元验证（临时 WebDAV 客户端）：Windows Flutter 全量 2369 项通过、2 项既有宿主跳过，严格分析零诊断，LCOV 22,289/36,839 行（60.50%），11 个 Dart 文件格式、结构/架构（95 个入口）、Git 依赖/版本/diff 检查及 Windows release 通过。真实原生断链、上传清理与 SDK/同步专项保留证据，日志为 `logs/sync-client-*.log`，产物记录为 `sync-client-artifact-hashes.json`。更早的 59ffa38 单元 2316 项/60.31%、Windows 分享 6 组及 Android 13 项回归继续保留。本机 Flutter 3.41.6/Dart 3.11.4 不替代声明 Flutter 3.41.4 或其他平台验收。

初始审计证据（最新阶段结果见执行记录）：全量 Windows Flutter 986 项通过；分析零错误/警告、23 个 info；LCOV 13,988/31,156 行（44.90%）。覆盖率是本机最新 `coverage/lcov.info`，不是性能结果，也不证明目标行为完整。架构报告有 36 个受控业务入口；功能聚合环仍为 comic_details、favorites、history、local_comics、reader、search、sync，包含 UI，不据此断言纯业务环已消除。

## 原方案逐项状态

| 原方案项 | 状态 | 要求 | 已检查证据 | 尚需执行/验收 |
|---|---|---|---|---|
| P0.1 | I | 起点与工作区隔离 | `optimization_progress.zh.md` | 保留起点 550fcff 与用户改动清单；后续提交继续选择性暂存。 |
| P0.2 | I | 分析范围 | `analysis_options.yaml` | 仅排除 build；检查正式源码仍启用。 |
| P0.3 | P | 测试与覆盖率 | `optimization_progress.zh.md` 最新执行记录 | 本轮最终生产源码全量 2658 项通过/2 项既有跳过、LCOV 63.06%；补齐测试原生库可用性判断后，4 项 QuickJS 实际执行通过，生产源码未改。严格分析、格式、Python 74 项/3 项既有跳过、静态门禁与 Windows release 均通过；其他平台及完整验收矩阵仍未完成。 |
| P0.4 | P | 依赖报告与例外 | `dependency_baseline.json; check_architecture_dependencies.py` | 本轮登记 103 个业务入口，结构与架构门禁通过且未扩大依赖例外。继续扩展到未迁移服务并核查业务环。 |
| P0.5 | U | 设备性能基线 | `optimization_progress.zh.md: 性能基线与平台补验` | 固定设备、样本和构建模式测量六类场景，记录至少三次波动。 |
| P1.1 | I | Channel 清理 | `git ls-files lib/foundation/channel.dart` | 文件已不再跟踪；历史判定见执行记录。 |
| P1.2 | I | 组件聚合入口 | `git ls-files lib/components/components.dart` | 文件已不再跟踪；保留使用中的组件。 |
| P1.3 | I | 完整候选分类 | `public_symbol_audit.zh.md; public_symbol_candidates.json; tool/code_audit` | 原 36 项调查现已全部处理；最终复扫 379 个生产文件、6036 个声明、304 个候选，无新增未分类项。详见 investigation_resolution.zh.md；历史数量不代表当前扫描。 |
| P1.4 | I | 仓库临时产物审查 | `dependency_artifact_audit.zh.md` | 已核对 881 个跟踪路径、27 个工具与 14 组相同内容；无跟踪临时输出，平台资源保留。ARM64 手工入口已复用 Windows 共用打包流程，保留命令适配；6 项脚本回归通过，真实 ARM64 构建仍需平台补验。 |
| P1.5 | I | 依赖用途核对 | `dependency_artifact_audit.zh.md; pubspec.yaml; pubspec.lock` | 51 项原声明逐项核对 Dart、配置、原生插件与 JS 桥；删除无调用的 flutter_to_arch 及独占 io，保留 Python 消费的配置。其余版本/来源不变；不替代 fork 许可、平台构建及公开符号审查。 |
| P2.1 | P | 业务/UI 入口 | `dependency_baseline.json; lib/features/comic_source/comic_source_api.dart` | 补齐本地/同步/WebDAV 等遗留聚合依赖。 |
| P2.2 | I | 源更新服务 | `lib/features/comic_source/source_update_service.dart` | 服务已存在并被调用；后续 P4/P7 收束全局依赖与错误翻译。 |
| P2.3 | P | 页面与 CLI 适配 | `lib/app_runtime/headless.dart; lib/app_runtime/headless_sync_command.dart` | 同步/源/订阅输出适配、参数预检及受控 Dart 子进程协议已有验证；真实服务装配、间接 UI 依赖及完整 Flutter 无头程序仍需验收。 |
| P2.4 | I | 本地阅读目标与路由 | `lib/features/local_comics/local_reading.dart; lib/routing/local_reading.dart` | 模型导航已迁出，保留章节/历史回归。 |
| P2.5 | P | 跨域接口所有者 | `lib/features/reader/chapter_image_loader.dart; lib/features/sync/data_sync.dart` | 同步参与者和部分源/本地管理器仍直接耦合。 |
| P3.1 | I | 阅读设置规则 | `lib/foundation/reader_preferences.dart` | 默认值与范围集中；后续修改保持旧值语义。 |
| P3.2 | I | 不可变设置解析 | `lib/foundation/reader_settings.dart; test/foundation/reader_settings_snapshot_test.dart` | 已存在快照与覆盖测试；不得用这项替代所有设置验收。 |
| P3.3 | P | 存储与消费端类型化 | `lib/foundation/reader_preference_store.dart; lib/features/settings/reader.dart` | 阅读消费端已有迁移，仍需全消费端盘点与用户改动合并验收。 |
| P3.4 | P | 非法值与往返兼容 | `test/foundation/reader_preference_store_test.dart; test/foundation/sync_configuration_test.dart` | 补齐旧配置往返、未知字段及全部导入路径交叉矩阵。 |
| P3.5 | P | 其他配置与门禁 | `lib/foundation/application_configuration.dart; lib/features/webdav_library/webdav_library_settings.dart` | 网络/外观/数据同步/WebDAV 已有快照；WebDAV 设置存储可注入，运行时装配已移入 app_runtime，六个业务入口受控；继续全配置消费端验收。 |
| P4.1 | I | 初始化共享与失败 | `lib/foundation/init.dart; test/foundation/init_test.dart` | 状态机与显式重试已实现。 |
| P4.2 | P | 启动依赖审计 | `lib/app_runtime/bootstrap_core.dart` | 关键/可选顺序已显式；仍需全 ensureInit 调用和失败资源清单。 |
| P4.3 | I | 启动模式分离 | `lib/app_runtime/core_bootstrap.dart; lib/app_runtime/interactive_bindings.dart; lib/app_runtime/headless_bindings.dart` | 代码组装已分离；真实 CLI 冒烟归 P0/P8 验收。 |
| P4.4 | P | 依赖与启动/释放 | `lib/features/sync/data_sync.dart; lib/features/webdav_library/webdav_library_source.dart; lib/app_runtime/window_placement.dart` | 同步、WebDAV、交互绑定与窗口位置已有显式所有权；位置保存覆盖原生初始化、三代挂载交接及部分写失败恢复。桌面核心不可逆关闭、其余管理器与原生资源仍待收敛。 |
| P4.5 | P | 阅读请求所有权 | `lib/network/shared_image_requests.dart; lib/network/rhttp_stream_request.dart; lib/features/reader/display_image_provider.dart; lib/foundation/image_work.dart; lib/foundation/image_save_work.dart; lib/foundation/share_file_operation.dart` | 阅读原始任务、页面保存、首帧转换和 provider 身份/章节恢复已有基线证据；成功缓存与其他消费者保留。本轮分享拥有独立来源与窗口等待，Windows/Apple 派发后保留输入，Android 输入与插件副本分别持有，并增加 Windows/Android 原生定向回归。继续 Apple activity 错误报告、真实外部消费与平台生命周期验收、live-only 即时重试、剩余同步/网络消费者及更深原生/桌面核心关闭；没有 TTL/启动清扫或外部消费结束保证。 |
| P4.6 | P | 取消、释放与提交 | `lib/features/local_comics/local_import_lifecycle.dart; lib/features/reader/reader_session.dart` | 正常窗口已协调；系统终止/后台和跨文件数据库回滚仍未完成。 |
| P4.7 | I | 退出全局 State 查找 | `lib/features/reader/reader_tap_scope.dart; comic_image.dart; gesture.dart` | 图片重试已通过最近祖先 ReaderTapScope 抑制点击，手势 State 取消全局注册；独立图片、嵌套/替换宿主及事件顺序已有回归。其他 State 耦合仍见 P5。 |
| P5.1 | I | 阅读位置模型 | `lib/features/reader/image_position.dart; lib/features/reader/chapters.dart` | 已有模型及位置/分组回归。 |
| P5.2 | I | 页码与跨章策略 | `lib/features/reader/page_layout.dart; test/features/reader/page_navigation_test.dart` | 策略已提取；最终七模式联合验收仍独立。 |
| P5.3 | I | 控制器与不可变输入 | `lib/features/reader/reader_controller.dart; lib/features/reader/images.dart:79` | ReaderController 已接管内容加载阶段、取消与结果提交；视口挂载已归 ReaderViewportBinding 且宿主仅提供只读视口；页序迁移结果与一次性恢复由 ReaderPageOrderMigration 持有；ReaderImages 通过显式加载/生命周期回调与内容快照工作，不再持有 ReaderState；具体页面装配位于 ReaderImagesHost，阅读壳仍见 P5.6。 |
| P5.4 | I | 章节访问注入 | `lib/features/reader/chapter_image_loader.dart; test/features/reader/chapter_image_loader_test.dart` | 已有本地优先/在线回退适配与回归。 |
| P5.5 | I | 阅读视图与视口 | `lib/features/reader/gallery_view.dart; lib/features/reader/continuous_view.dart; lib/features/reader/reader_viewport.dart` | ReaderImages 已独立于 ReaderState，画廊/连续视图采用配置快照与导航/视口协议；独立内容生命周期及模式/自动阅读/滑块联合回归通过，平台行为仍需总体验收。 |
| P5.6 | P | 阅读壳与菜单 | `lib/features/reader/scaffold.dart; lib/features/reader/progress_bar.dart` | 滑动收藏由 ImageFavoriteSwipeBinding 持有唯一订阅，ReaderGesturePort 替代具体手势 State，挂载/解绑不再依赖延时；5 项回归通过；ReaderImagePicker 独立处理选择与内容身份，收藏/导出统一拒绝过期选择，新增 12 项回归。侧栏已由 ReaderSidebarBinding 统一拥有请求/路由/交互释放，新增 10 项回归；底部按钮展示已独立为状态/回调输入，9 项布局与交互回归通过；其余菜单组装与壳职责仍需审查，保留用户修改与键盘/无障碍。 |
| P5.7 | P | 阅读会话与平台效果 | `lib/features/reader/reader_session.dart; lib/features/reader/orientation_controller.dart; lib/features/reader/volume_controller.dart` | 已有控制器；真实平台方向/音量/亮度及前后台联合验收缺失。 |
| P6.1 | I | 模型与仓储分离 | `lib/features/local_comics/local_repository.dart; lib/features/history/history_repository.dart; lib/features/favorites/favorites_repository.dart` | 主体 SQL 已迁入仓储；后续新增 SQL 继续遵守边界。 |
| P6.2 | P | 收藏业务职责 | `lib/features/favorites/read_later_service.dart; lib/features/favorites/favorite_updates_service.dart; lib/features/favorites/favorites_manager.dart` | 稍后阅读/追更已分离；管理器仍有全局依赖和统一生命周期待收束。 |
| P6.3 | P | 本地库与导入下载 | `lib/features/local_comics/local.dart; lib/features/local_comics/local_deletion_paths.dart` | 队列/仓储/迁移已拆分；删除保护同时核对文本路径和原生实际路径，保留章节也参与引用检查，真实 Windows 联接回归通过。SAF 仍用提供者路径；外部路径并发替换、删除回滚和未受保护写入者继续处理。 add/remove 已校验写入所有权，页序迁移持有存储保留；下载及外部 SQL 剩余边界见 local_storage_writer_audit.zh.md。 |
| P6.4 | I | WebDAV 实例化与拆分 | `lib/features/webdav_library/webdav_library_synchronizer.dart; lib/features/webdav_library/webdav_library_snapshot_store.dart; lib/features/webdav_library/webdav_library_source.dart` | 配置/发现/快照与缓存/同步协调/源适配已分离，实例注入和路径、增量同步、取消回归已有证据；仍受 P6 总体数据/性能/平台退出条件约束。 |
| P6.5 | P | 应用同步职责 | `lib/features/sync/data_sync_controller.dart; lib/features/sync/app_data_import_journal.dart; lib/app_runtime/data_sync.dart` | 独立导入日志与启动前恢复已接入，替换前保留不可变备份及完整资源清单；提交后清理和未提交回滚可跨进程续作。恢复中再次终止、真实导入器和 bootstrap 有回归；全写入者屏障、备份导入及其他数据/平台失败矩阵仍需完成。 |
| P6.6 | P | 同步窄接口与协议 | `lib/features/sync/data_sync_operation.dart; lib/features/sync/data_sync_recovery.dart; test/features/sync/data_sync_recovery_test.dart` | v2 操作关联导入终态与旧配置 checkpoint；匹配收据恢复通知/固定时间/设置，持久清 marker 后才 ack，不重复传输。退出排空真实恢复 I/O；重启保守保留 pending。v3 上传 journal/内容对账与条件写入已接入并有真实进程和生产 HTTP 组合回归，使用原 endpoint/快照/版本；旧记录、损坏或不匹配证据继续阻断。dirty 持久化窗口及导入期间真实编辑冲突仍需处理。 |
| P6.7 | P | 原子性约束 | `local_deletion_recovery.zh.md; local_deletion_journal.dart; local_deletion_storage.dart` | 三库事务与持久隔离目录日志已接入；异常回滚、清理重试、重开连接和管理器恢复均有测试。SAF 真机、强制终止/断电、外部写入与恢复冲突修复入口仍需验收。 已验证 Windows 独立 VM 三个确定终止窗口的三库/日志恢复协议；不替代完整应用、SAF、其他平台或断电验收。 |
| P7.1 | I | 按能力拆解析器 | `lib/features/comic_source/parser.dart; source_*_parser.dart; source_parser_context.dart` | 已拆分账户、发现、分类、搜索、收藏、图片、评论、漫画及元数据；源身份上下文固定。完整能力/错误矩阵继续按 P7.2/P7.5 验收。 |
| P7.2 | P | JS 与最小源兼容 | `source_capability_matrix.zh.md; test/features/comic_source/source_capabilities_test.dart; test/features/comic_source/source_comic_completion_test.dart` | 真实 QuickJS 已覆盖登录、重登录、游标、新旧分类、多能力隔离、图片配置/回调及图片脚本释放；本轮补详情原始 Promise 等待、嵌套模型脱离 JS 图及结果/异常引用释放专项。归档/投票/其余元数据、其他回调所有权与完整取消矩阵仍待补齐，专项不替代最终全量。 |
| P7.3 | I | 重复流程对照表 | `repeated_workflow_matrix.zh.md` | 已核对更新、图片、归档、同步和导入的调度、取消、所有权与提交差异；登记已有共享原语和不可合并语义。P7.4/P7.5 及数据/平台验收继续追踪。 |
| P7.4 | P | 仅抽真实共性 | `lib/foundation/throttled_task_runner.dart; lib/network/request_scope.dart; lib/foundation/platform_dialog_queue.dart; lib/network/webdav.dart` | 分享/保存用独立 PlatformDialogQueue 实例，无旧别名；closeWebDavClient 由数据同步和漫画备份复用临时连接释放，书库长连接保留独立协议。继续以 P7.3 对照核查其他共性与重复实现。 |
| P7.5 | P | 结构化错误 | `lib/features/comic_source/source_update_service.dart; lib/foundation/res.dart; lib/foundation/share_file_operation.dart` | 源仓库/更新与目录预览已有稳定错误码、原始异常及范围，UI/CLI 在边界展示；取消不误计 CLI 成功，FailureDetails/Res 区分失败、取消和 UnsupportedError，八类源解析器保留异常。本轮 ShareFileCleanupFailure 保留操作/清理双重错误与堆栈，Windows 保留 HRESULT，Android 保留 suppressed 清理诊断。其他服务、Apple activity 报错、字符串校验失败和全消费端分类展示仍待迁移。 |
| P7.6 | P | 技术规则复用 | `lib/features/comic_source/parser.dart:23; lib/features/comic_storage/archive_metadata.dart` | 元数据/文件规则已有公共实现；版本比较/日期等仍需用途和兼容审查。 |
| P8.1 | P | 兼容与测试开关退场 | `lib/features/local_comics/local.dart:52; lib/app_runtime/data_sync.dart` | 同步单例/reset/debug、9 个归一化 debug 转发及 JSAutoFreeFunction 已删除；本地漫画等域仍有 reset/debug，聚合导出继续审查。 无调用的旧批量归档执行器已退役，历史元数据编解码独立保留，不构成当前导入入口。  原 36 项调查现已全部处理；最终复扫 379 个生产文件、6036 个声明、304 个候选，无新增未分类项。详见 investigation_resolution.zh.md；历史数量不代表当前扫描。 |
| P8.2 | P | 恢复 lint 与边界类型 | `analysis_options.yaml` | collection_methods_unrelated_type 已启用并提升为 warning，25 处诊断已处理；use_build_context_synchronously 已提升为 warning，导入展示修复 21 处、评论视图修复 8 处、源页面修复 8 处、本地库修复 3 处、同步窗口修复 1 处，历史页面修复 2 处，收藏面板修复 7 处，网络收藏页修复 9 处，应用设置修复 9 处，本地收藏设置/图片统计各修复 1 处，富文本评论修复 1 处，详情点赞/评分修复 4 处，详情下载修复 3 处，本地收藏文件导入修复 2 处，网络收藏批量导入修复 1 处，调试提示/本地跳转各修复 1 处，阅读手势最后 2 处已修复，剩余 0；剩余 21 项 info 已处理，严格分析清零且 CI 对 info 失败；Settings 异构兼容入口仍显式 dynamic，全面消费端类型化按 P3 继续，P8.2 尚不代表全部边界已收束。 |
| P8.3 | P | CI 与覆盖趋势 | `.github/workflows/analyze.yml` | 检查和覆盖上传已有；未登记服务仍不受业务入口门禁约束。 |
| P8.4 | P | 最终平台与性能验收 | `optimization_progress.zh.md; platform_validation_2026_10_04.zh.md; .github/workflows/build.yml` | 本轮 Windows release 构建成功，打包 CHANGELOG 与源码哈希一致；上一单元构建与真实原生断链/上传清理、59ffa38 分享 Windows 6 组及 Android 13 项回归保留历史证据。分享 UI/外部接收者未验收，Flutter 本机版本不同于声明，完整 CLI、五平台安装启动与固定设备性能仍待补验。 |
| P8.5 | P | 最终删除/技术债报告 | `optimization_acceptance.zh.md` | 本清单建立追踪入口；剩余项完成后逐项复核，不用总测试数替代验收。 |

## 总体验收（原方案第 9 节）

| 条目 | 当前结论 | 完成所需证据 |
|---|---|---|
| 9.1 业务不依赖页面/State | 未完成 | ReaderImages/全局手势 State 已有退场证据；继续扩展业务入口登记并移除残余反向 UI 引用 |
| 9.2 业务环与 CI | 未证明 | 对全部关键业务服务检查传递依赖，分类保留 UI 环；103 个受控入口结构/架构门禁通过，仍不是全库无业务环的证明 |
| 9.3 阅读器控制器与策略 | 部分 | P5.3/P5.5 已有实现证据；完成 P5.6 剩余阅读壳职责、七模式及平台效果联合验收。原用户未提交功能已按授权撤销 |
| 9.4 依赖与生命周期 | 部分 | WebDAV 实例隔离和 DataSync 端口注入已有回归；继续宿主/核心/图片/原生完整退出、其他生产全局 reset 退场和失败释放矩阵 |
| 9.5 删除与兼容层 | 未完成 | P1 候选判定已完成一轮；继续所有兼容转发真实调用审查、P8.1 退场及最终复扫 |
| 9.6 数据/JS/CLI/平台 | 未证明 | 旧样本/合成源/真实 CLI 子进程及五平台证据，列明不支持项和实际跳过原因 |
| 9.7 性能与覆盖 | 未证明 | 固定设备前后数据；最新 LCOV 仅为行覆盖快照，不作为性能通过阈值 |
| 9.8 文档与代码一致 | 进行中 | 本清单和执行记录已建立；每一阶段更新结构、边界与 CHANGELOG，最终复核失效说明 |

## 命令与交付物核对（图片收藏/封面保存历史单元）

- 本轮图片收藏/封面保存的最终全量、严格分析、覆盖率、Windows release 构建及门禁均通过；日志均在上述仓库外 artifacts 目录。构建日志 `logs/favorite-save-windows-release.log`，产物记录 `favorite-save-artifact-hashes.json`，打包 CHANGELOG 与源码哈希一致。
- `flutter test --no-pub --coverage --coverage-path <仓库外路径> --reporter expanded`：最终日志 `logs/favorite-save-full-final.log`，2278 项通过；覆盖率 `coverage/favorite-save-lcov.info`，22,078/36,674 行（60.20%）。
- `flutter analyze --no-pub --fatal-infos --fatal-warnings`：最新日志 `logs/favorite-save-analyze-final.log`，零诊断，位于上述仓库外 artifacts 目录。
- `python .github/scripts/check_structure_imports.py --print-feature-dependencies` 与 `python .github/scripts/check_architecture_dependencies.py --report`：最终检查通过，93 个业务入口受控；日志 `logs/favorite-save-{structure-final,architecture-final}.log`。
- Git 依赖、49 个修改/新增 Dart 文件格式与完整 Python 脚本测试已执行；Python 使用 UTF-8 模式共 74 项、3 项既有平台跳过，日志 `logs/favorite-save-python-final.log`。实际 release_version.py --check 通过。单独架构脚本测试不能替代全集。
- `.github/workflows/analyze.yml` 已配置结构、架构、完整 Python 单测、锁定依赖、修改文件格式、分析、Flutter 测试及 coverage 摘要/上传。配置存在不代表本轮远端 CI 已通过；未新建 PR、未取得五平台成功 run 的证据。
- P7 重复流程对照表及 P1 候选分类/调查处理已有提交证据；固定设备性能结果表与全部迁移后的最终复扫仍需交付，不能只写“技术债”后豁免。
- 原方案第 6 节 20 个提交单元对应：01–02→P0；03→P1；04–06→P2；07–08→P3；09–11→P4；12–14→P5；15–18→P6（18 另含 P3）；19→P7；20→P8。每个单元仍受上述任务/总体验收约束，提交数量不是验收标准。
- 原方案第 7 节矩阵：纯逻辑/数据夹具/异步故障/Widget/核心集成已有测试证据但需针对剩余修改继续更新；真实 CLI、五平台、性能三类尚未完成集中验收。第 8 节数据格式、备份恢复、原子性和跨版本约束不因现有测试通过而取消。

## 后续执行顺序

1. 继续普通收藏、appdata、源与跨库写入的准入，处理数据落盘到 dirty 持久化窗口、内容基线、导入期间真实编辑冲突及漫画备份导入/删除失败。此前图片、分享和远端关闭证据保留；其余消费者、live-only 重试及窗口/核心排空仍逐项验收。
2. 窗口位置保存及其跨挂载交接已有实现；继续桌面宿主持有核心、其他服务跨挂载归属和不可逆关闭终态，同步补 SAF/剩余网络等原生生命周期，不能在任务尚未排空时先关闭核心资源。
3. 完成 P2/P3 的遗留业务与配置边界、P5 的阅读壳，以及 P6 的存储/同步失败恢复矩阵；保留已完成的 WebDAV/仓储/控制器拆分和旧协议。
4. 补齐 P7 其余能力/错误/取消矩阵、同 key 源保存与替换互斥、技术规则复用和 P8 兼容层退场。解析器能力拆分与重复机制对照已完成一轮；严格 lint 已清零，后续保持。
5. 执行完整 CLI、五平台、固定设备性能及最终复扫；逐项复核本清单与第 9 节后才能完成目标。

审计不改变原目标或豁免未完成项。P0 设备基线、P1 最终复扫和 P3 剩余配置在相关步骤补齐；平台不可用时保留未验证，不以 Windows 测试代替其他平台。

P6/P7 网络收藏导入增量证据：抓取/事务提交/UI 生命周期已分离，取消与抓取失败无提交，分页重试/游标检查和 SQL 回滚有专项；见 network_favorite_import.zh.md。提交后发布失败、真实源协议和平台退出仍待验收。

网络收藏导入提交结果与缓存/通知发布已分离，刷新失败保留成功计数并仅重试发布；本地 JSON 导入、跨进程通知恢复及其他提交后发布边界仍待验收。

P4.2/P4.4 增量审计：全部 4 处 ensureInit 等待、3 个 Init 混入者与核心步骤的失败资源清单见 initialization_ownership_audit.zh.md。源仓库迁移失败可重试已修复；History 初始化、JS/Dio、部分源注册与统一核心释放仍明确待办。

HistoryManager.init 现在共享一次完成结果，仅在过期清理与已接受写入完成后通知就绪；图片收藏表直接由所属连接初始化，已删除无调用的 ImageFavoriteManager.init 转发。失败清理、关闭重开与独立实例边界有专项覆盖，核心服务整体退出仍未验收。

JsEngine.create 允许显式注入其拥有的 HTTP 客户端工厂和初始化脚本加载器；生产单例使用默认装配。初始化失败和销毁共用释放逻辑，临时 dart:io 客户端按请求释放，resetDio 允许旧请求结束后关闭连接。reset 返回可等待 Future，销毁对象不可复用。

CookieJarSql 在构造阶段拥有并初始化数据库，建表失败释放连接，关闭后访问明确失败；SingleInstanceCookieJar.dispose 仅清除自己的全局引用，导入装配不再手动写空/重复赋值。移除无外部调用的 init 入口，防止重复打开泄漏连接。

foundation/opencc_table.dart 是不依赖 Flutter 的不可变单字转换表，按 Unicode 码点解析并处理 CRLF，保留重复键末项优先。OpenCC 仅负责资源加载/共享初始化与原有静态 API 适配，加载失败可重试；新增第 78 个业务入口门禁。

ComicSourceManager 启动加载复用 ComicSourceParser 的 retainRollback 协议；整批加载失败清理本次注册，成功后才释放回滚句柄并启动源 init。单个坏脚本继续隔离。全量 reload 的旧源恢复、后台 init 取消和监听器退出仍需验收。

全量源重载复用 _loadSources 和解析器回滚，保留原 Dart 列表与 JS 注册表；已有脚本解析失败或整批失败恢复原状态，成功后才释放未复用旧源。复用的运行时对象失败时不被释放，新增坏脚本与删除文件沿用原有语义。

P2.3/P4.4 增量（2026-10-04）：CoreBootstrap.close 已接入无头 finally，成功/失败均尝试完整清理；源 init/保存/通知在解绑前排空，Cookie 导入替换和 WebDAV 释放有原生 Windows 回归。正常桌面任务冻结、追更/WebDAV/阅读排空、SAF/Rhttp、五平台与性能仍未验收；详见最新执行记录。

P4.4/P4.6 增量（2026-10-04）：追更检查准备已接入窗口，覆盖前台、后台、已被替换的旧任务和直接单漫画检查，独立等待业务 done；失败/解绑恢复限制。全局桌面路由冻结、WebDAV/阅读全部请求及核心不可逆关闭仍待实现。原未提交阅读器功能已按用户要求撤销，后续结果针对干净起点的新改动。

P4.4/P4.6/P6.4 增量（2026-10-04）：WebDAV 源、同步器和快照现有可等待关闭/可恢复准备，覆盖旧配置任务、直接测试/章节请求与最终提交。实际 SDK CancelToken 传递到 Rhttp，元数据传输另等原始 bytes 请求完成，窗口及核心已接入。联合专项 106 项通过；图片/归档流式传输、阅读器、宿主重挂载归属、全局输入冻结、不可逆核心关闭及平台/性能仍未完成，不能据此将 P4 总体标记完成。

P4/P5 窗口增量（2026-10-04）：关闭守卫通过后阻断内容指针/键盘/无障碍动作，取消活动手势；普通导航和延迟侧栏受局部入场边界控制。退出回调后追加的保存及失败分支也排空，窗口失败恢复已准备服务和原焦点。44 项专项与深浅色大字号渲染通过；原生关闭与核心所有权、阅读请求、直接导航/异步设置的剩余边界及平台/性能仍按原目标推进。

P4 平台事件增量（2026-10-04）：订阅取消现与实际异步处理一起等待，准备期间丢弃排队及新事件，恢复回调按代次隔离。窗口先准备平台事件，失败/解绑先等当前准备再释放前序限制；最终绑定释放排空心跳并保留全部订阅取消错误。Windows 原生监控有 5 秒超时退出策略，可恢复准备保留心跳。原生监控线程关闭、宿主/核心/阅读/SAF/Rhttp 所有权及五平台/性能仍待完成，详见最新执行记录。

P4 Windows 监控后续（2026-10-04）：监控现由原生窗口持有并可显式停止，使用挂载编号隔离迟到请求；Dart 绑定最终释放等待调用后停止原生线程。15 项 Dart 专项、CTest 2/2 与 Windows release 构建通过。此补项不替代桌面核心不可逆退出、完整宿主/阅读/其他原生资源，以及五平台和性能验收。

P4.5 图片流增量（2026-10-04）：最后一个订阅者的释放现等待源流取消及 finally，其他共享拥有者不受影响，32 项联合专项通过。源配置原始 Promise、退休请求全局登记、原生流、解码/导出和窗口整体排空仍未验收，P4.5 保持部分完成。

P4.5/P7.2 图片配置后续（2026-10-04）：取消时原配置 resolver Future 已保留并等待，迟到有效结果释放全部未交付 JS 引用；35 项专项通过。正常配置/解析失败值、退休请求、原生流与窗口/核心整体仍继续，不将 P4.5 或 P7.2 标为全部完成。

P4/P5/P6 阅读保存后续（2026-10-04）：历史时长写入已有明确提交状态；进度/时长失败保留并按快照或未提交时段安全重试，会话提供可组合 hold 与可恢复准备。窗口首次等待前停表，真实阅读器返回路径先保存再离开，失败保留页面和显式不保存离开入口；详情及最终验证见最新执行记录。图片/源/解码/导出/预缓存整体排空、宿主重挂载、核心不可逆退出与平台/性能仍未完成，P4/P5 继续保持部分状态。
