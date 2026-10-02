# 架构优化逐项验收清单

审计基点：`99e607d`，2026-10-02。工作区包含原有用户修改；检查结果针对该工作区，不能当作仅 HEAD 的验证。原方案范围完整保留。本文件是执行索引，不是完成声明。

状态：I = 当前已核对到实现证据（仍受总体验收约束）；P = 部分实现；O = 代码明确显示未完成；U = 缺少足够验证。I 不代表整个阶段完成。证据列的短文件名位于本目录或 `.github/scripts/`，其余为仓库相对路径。

初始审计证据（最新阶段结果见执行记录）：全量 Windows Flutter 986 项通过；分析零错误/警告、23 个 info；LCOV 13,988/31,156 行（44.90%）。覆盖率是本机最新 `coverage/lcov.info`，不是性能结果，也不证明目标行为完整。架构报告有 36 个受控业务入口；功能聚合环仍为 comic_details、favorites、history、local_comics、reader、search、sync，包含 UI，不据此断言纯业务环已消除。

| 原方案项 | 状态 | 要求 | 已检查证据 | 尚需执行/验收 |
|---|---|---|---|---|
| P0.1 | I | 起点与工作区隔离 | `optimization_progress.zh.md` | 保留起点 550fcff 与用户改动清单；后续提交继续选择性暂存。 |
| P0.2 | I | 分析范围 | `analysis_options.yaml` | 仅排除 build；检查正式源码仍启用。 |
| P0.3 | P | 测试与覆盖率 | `output/directory-reference-full.log; coverage/lcov.info` | Windows 986 项通过；其他平台与全部脚本跳过归属仍需验收。 |
| P0.4 | P | 依赖报告与例外 | `dependency_baseline.json; check_architecture_dependencies.py` | 36 个业务入口受控；扩展到未迁移服务并核查业务环。 |
| P0.5 | U | 设备性能基线 | `optimization_progress.zh.md: 性能基线与平台补验` | 固定设备、样本和构建模式测量六类场景，记录至少三次波动。 |
| P1.1 | I | Channel 清理 | `git ls-files lib/foundation/channel.dart` | 文件已不再跟踪；历史判定见执行记录。 |
| P1.2 | I | 组件聚合入口 | `git ls-files lib/components/components.dart` | 文件已不再跟踪；保留使用中的组件。 |
| P1.3 | U | 完整候选分类 | `optimization_plan.zh.md P1.3` | 补交动态入口、测试工具、兼容协议和待调查符号清单。 |
| P1.4 | U | 仓库临时产物审查 | `git status --short` | 工作区差异已保留；仍需独立完成已跟踪产物清单。 |
| P1.5 | P | 依赖用途核对 | `tool/check_git_dependencies.dart` | Git 声明/锁定检查通过不证明所有包都有生产用途。 |
| P2.1 | P | 业务/UI 入口 | `dependency_baseline.json; lib/features/comic_source/comic_source_api.dart` | 补齐本地/同步/WebDAV 等遗留聚合依赖。 |
| P2.2 | I | 源更新服务 | `lib/features/comic_source/source_update_service.dart` | 服务已存在并被调用；后续 P4/P7 收束全局依赖与错误翻译。 |
| P2.3 | P | 页面与 CLI 适配 | `lib/app_runtime/headless.dart` | 服务调用已有；真实无头子进程参数/输出/退出协议仍需集中验收。 |
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
| P4.4 | P | 依赖与启动/释放 | `lib/features/sync/data_sync.dart; lib/features/webdav_library/webdav_library_source.dart` | DataSync 有 start/dispose；WebDAV 已实例化并由应用挂载生命周期释放；其余管理器和启动失败资源仍待收敛。 |
| P4.5 | P | 阅读请求所有权 | `lib/network/request_scope.dart; lib/features/reader/chapter_loader.dart; lib/features/reader/image_precache.dart` | 已有会话和共享请求回归；补完全部源请求及实机退出/前后台验收。 |
| P4.6 | P | 取消、释放与提交 | `lib/features/local_comics/local_import_lifecycle.dart; lib/features/reader/reader_session.dart` | 正常窗口已协调；系统终止/后台和跨文件数据库回滚仍未完成。 |
| P4.7 | O | 退出全局 State 查找 | `lib/features/reader/comic_image.dart:358` | 仍调用 GlobalState.find<ReaderGestureDetectorState>；改为显式交互协议。 |
| P5.1 | I | 阅读位置模型 | `lib/features/reader/image_position.dart; lib/features/reader/chapters.dart` | 已有模型及位置/分组回归。 |
| P5.2 | I | 页码与跨章策略 | `lib/features/reader/page_layout.dart; test/features/reader/page_navigation_test.dart` | 策略已提取；最终七模式联合验收仍独立。 |
| P5.3 | P | 控制器与不可变输入 | `lib/features/reader/reader_controller.dart; lib/features/reader/images.dart:79` | 仍直接写 reader.localPageOrderChecked/imageViewController；移出具体 State 依赖。 |
| P5.4 | I | 章节访问注入 | `lib/features/reader/chapter_image_loader.dart; test/features/reader/chapter_image_loader_test.dart` | 已有本地优先/在线回退适配与回归。 |
| P5.5 | P | 阅读视图与视口 | `lib/features/reader/gallery_view.dart; lib/features/reader/continuous_view.dart; lib/features/reader/reader_viewport.dart` | 已有视图分拆；ReaderImages 仍持有 ReaderState，完成宿主协议后复验模式。 |
| P5.6 | P | 阅读壳与菜单 | `lib/features/reader/scaffold.dart; lib/features/reader/progress_bar.dart` | scaffold 当前 914 行且有用户修改；继续按职责与交互边界拆分，保留键盘/无障碍。 |
| P5.7 | P | 阅读会话与平台效果 | `lib/features/reader/reader_session.dart; lib/features/reader/orientation_controller.dart; lib/features/reader/volume_controller.dart` | 已有控制器；真实平台方向/音量/亮度及前后台联合验收缺失。 |
| P6.1 | I | 模型与仓储分离 | `lib/features/local_comics/local_repository.dart; lib/features/history/history_repository.dart; lib/features/favorites/favorites_repository.dart` | 主体 SQL 已迁入仓储；后续新增 SQL 继续遵守边界。 |
| P6.2 | P | 收藏业务职责 | `lib/features/favorites/read_later_service.dart; lib/features/favorites/favorite_updates_service.dart; lib/features/favorites/favorites_manager.dart` | 稍后阅读/追更已分离；管理器仍有全局依赖和统一生命周期待收束。 |
| P6.3 | P | 本地库与导入下载 | `lib/features/local_comics/local.dart; lib/features/local_comics/local_deletion_paths.dart` | 队列/仓储/迁移已拆分；符号链接、删除回滚和未受保护直接写入者仍需处理。 |
| P6.4 | P | WebDAV 实例化与拆分 | `lib/features/webdav_library/webdav_library_settings.dart; lib/features/webdav_library/webdav_library_source.dart` | 配置与存储已拆出；缓存、in-flight、ops、同步状态已实例化并有会话隔离/释放回归；继续目录发现、快照和传输职责拆分。 |
| P6.5 | P | 应用同步职责 | `lib/features/sync/data_sync.dart; lib/features/sync/app_data_archive.dart; lib/app_runtime/sync_window_binding.dart` | 归档/窗口已迁出；DataSync 仍组合调度、传输和全局参与者。 |
| P6.6 | P | 同步窄接口与协议 | `lib/features/sync/data_sync.dart; test/features/sync/data_sync_schedule_test.dart` | 保留三模式回归；参与者注入、pending 重启和不回传最终矩阵待完成。 |
| P6.7 | P | 原子性约束 | `lib/foundation/sqlite_transaction.dart; lib/foundation/directory_replacement.dart; lib/features/local_comics/local.dart` | 已有事务/恢复工具；删除仍可能跨文件/数据库部分提交。 |
| P7.1 | O | 按能力拆解析器 | `lib/features/comic_source/parser.dart` | 1349 行仍含搜索/分类/图片/评论注册解析；按真实能力逐项拆出。 |
| P7.2 | P | JS 与最小源兼容 | `assets/init.js; test/features/comic_source/source_parser_test.dart` | 现有 parser 测试只验证类声明；补充合成源的能力/桥接执行矩阵。 |
| P7.3 | U | 重复流程对照表 | `optimization_plan.zh.md P7.3` | 补交更新/图片/归档/同步/导入机制与业务差异表。 |
| P7.4 | P | 仅抽真实共性 | `lib/foundation/throttled_task_runner.dart; lib/network/request_scope.dart` | 现有原语可复用；以 P7.3 对照证明新增抽象并删除对应重复实现。 |
| P7.5 | O | 结构化错误 | `lib/features/comic_source/source_update_service.dart; lib/foundation/res.dart` | 更新服务仍抛翻译字符串；建立失败/取消/不支持与 Res 适配边界。 |
| P7.6 | P | 技术规则复用 | `lib/features/comic_source/parser.dart:23; lib/features/comic_storage/archive_metadata.dart` | 元数据/文件规则已有公共实现；版本比较/日期等仍需用途和兼容审查。 |
| P8.1 | O | 兼容与测试开关退场 | `lib/features/local_comics/local.dart:52; lib/features/sync/data_sync.dart:252` | 仍有生产全局 reset/debugSkip；在依赖注入完成后删除并审查聚合导出。 |
| P8.2 | O | 恢复 lint 与边界类型 | `analysis_options.yaml` | collection_methods_unrelated_type 与 use_build_context_synchronously 仍为 false。 |
| P8.3 | P | CI 与覆盖趋势 | `.github/workflows/analyze.yml` | 检查和覆盖上传已有；未登记服务仍不受业务入口门禁约束。 |
| P8.4 | U | 最终平台与性能验收 | `.github/workflows/build.yml; optimization_progress.zh.md` | 构建工作流存在不等于本轮运行成功；收集五平台结果和固定设备复测。 |
| P8.5 | P | 最终删除/技术债报告 | `optimization_acceptance.zh.md` | 本清单建立追踪入口；剩余项完成后逐项复核，不用总测试数替代验收。 |

## 总体验收（原方案第 9 节）

| 条目 | 当前结论 | 完成所需证据 |
|---|---|---|
| 9.1 业务不依赖页面/State | 未完成 | 扩展业务入口登记；移除 ReaderImages/全局手势 State 依赖及残余反向 UI 引用 |
| 9.2 业务环与 CI | 未证明 | 对全部关键业务服务检查传递依赖，分类保留 UI 环；36 个入口通过不是全库证明 |
| 9.3 阅读器控制器与策略 | 部分 | 完成 P5.3/P5.5/P5.6，七模式联合回归及用户现有手势修改集成 |
| 9.4 依赖与生命周期 | 部分 | WebDAV 实例隔离已有回归；继续 DataSync 参与者注入、其他生产全局 reset 退场和完整失败释放矩阵 |
| 9.5 删除与兼容层 | 未完成 | P1 候选判定清单、所有兼容转发真实调用审查、P8.1 退场记录 |
| 9.6 数据/JS/CLI/平台 | 未证明 | 旧样本/合成源/真实 CLI 子进程及五平台证据，列明不支持项和实际跳过原因 |
| 9.7 性能与覆盖 | 未证明 | 固定设备前后数据；当前 44.90% 仅为行覆盖快照，不作为通过阈值 |
| 9.8 文档与代码一致 | 进行中 | 本清单和执行记录已建立；每一阶段更新结构、边界与 CHANGELOG，最终复核失效说明 |

## 命令与交付物核对

- `flutter test --no-pub --coverage --reporter expanded`：最近完成日志 `output/directory-reference-full.log`，986 项通过；本轮仅文档审计未重复运行。
- `flutter analyze --no-pub --no-fatal-infos`：最近日志 `output/directory-reference-analyze.log`，23 个 info、无 error/warning。CI 另显式使用 `--fatal-warnings`。
- `python .github/scripts/check_structure_imports.py --print-feature-dependencies` 与 `python .github/scripts/check_architecture_dependencies.py --report`：本轮实际运行，成功；报告范围如前述。
- 架构脚本单测、Git 依赖和修改文件格式：此前对应代码提交已验证。本轮不能用 12 项架构脚本单测替代 CI 的 `python -m unittest discover -s .github/scripts/tests -p 'test_*.py'` 全集；最终须执行全集并解释跳过。
- `.github/workflows/analyze.yml` 已配置结构、架构、完整 Python 单测、锁定依赖、修改文件格式、分析、Flutter 测试及 coverage 摘要/上传。配置存在不代表本轮远端 CI 已通过；未新建 PR、未取得五平台成功 run 的证据。
- 未发现已提交的固定设备性能结果表、P7 重复流程对照表、最终全量死代码判定表；这些交付物保留为未完成项，不能只写“技术债”后豁免。
- 原方案第 6 节 20 个提交单元对应：01–02→P0；03→P1；04–06→P2；07–08→P3；09–11→P4；12–14→P5；15–18→P6（18 另含 P3）；19→P7；20→P8。每个单元仍受上述任务/总体验收约束，提交数量不是验收标准。
- 原方案第 7 节矩阵：纯逻辑/数据夹具/异步故障/Widget/核心集成已有测试证据但需针对剩余修改继续更新；真实 CLI、五平台、性能三类尚未完成集中验收。第 8 节数据格式、备份恢复、原子性和跨版本约束不因现有测试通过而取消。

## 后续执行顺序

1. 继续 P6.4：配置/设置与运行实例已分离，应用装配/UI 绑定和会话失效测试已接入；下一步分离目录发现、快照构建及传输职责，保留增量同步与旧缓存兼容。
2. 完成 P6.5/P6.6：DataSync 调度/传输/数据参与者边界；完成本地删除失败恢复与符号链接策略的明确验收，而非继续新增零散例外。
3. 收束 P5 宿主 State/手势/阅读壳剩余接口，保留并整合用户未提交改动；同步补 P4 的生命周期与测试注入缺口。
4. 执行 P7 全部能力拆分、协议回归、重复机制对照和结构化错误；避免把解析器机械切成多个仍共用隐式状态的文件。
5. P8 退兼容、恢复 lint、完整脚本/CLI/平台/性能验证；逐项复核本清单与第 9 节后才能完成目标。

审计不改变原目标或豁免未完成项。P0 设备基线、P1 清理分类和 P3 剩余配置在相关步骤补齐；平台不可用时保留未验证，不以 Windows 测试代替其他平台。
