# 业务文件边界清单 / Business file boundary inventory

本清单对应原方案 P0.4、P2.1 和 P8.3。路径以 `lib/` 为根，完整、可执行的登记在 [dependency_baseline.json](dependency_baseline.json)，由 `.github/scripts/check_architecture_dependencies.py` 在 CI 中检查。

截至 2026-10-08，502 个 Dart 文件分属互斥的三组：319 个 `business_files`、134 个 `ui_files`、49 个 `pending_review_files`。234 个业务入口是业务组的子集。起始283个受控依赖全部保留；本轮登记历史保留修改入口，设置页退出原依赖环。移除调用或入口不会使已经登记的文件自动退出保护。

`pending_review_files` 是尚未完成职责核查的迁移清单，**不是 UI 分类结论，也不是业务依赖例外**。业务文件及其传递依赖不能到达 UI 或待审查文件，且不得成环。新增、删除、重复或跨组登记会触发检查；即使文件没有被任何入口引用，也必须登记。相对路径、package 导入、条件导入/导出及 part 的现有解析规则继续适用。

这一检查约束项目文件依赖，不是 Dart 符号级语义证明。Flutter painting、原生资源和手势值类型不等于 Widget 页面；不能通过禁止全部 Flutter 依赖代替职责核查。业务文件内部新增页面职责、待审查文件中的服务、全局资源所有权及跨域接口仍须代码审查。原有 45 个 UI 禁入文件和 16 个成环保护文件均保留，57 条允许的直接特性依赖未扩大。

This inventory is enforced for every library file, including disconnected files. Business membership persists independently of current reachability. Both UI and pending-review files are forbidden from business dependency closures, which must also remain acyclic. Pending review is an explicit migration backlog, not a claim that those files are presentation-only. This is a project-file dependency check, not Dart symbol-level proof or lifecycle acceptance.

## 首批核实的业务边界 / Initial inspected business boundaries

| 文件 | 核实依据与保留事项 |
|---|---|
| `features/comic_details/archive_download.dart` | 归档列表和链接校验；源聚合导入改为业务 API，异常转换规则未改。 |
| `features/comic_source/source_import.dart` | 解析、下载导入预览，不安装源或打开页面；已有翻译消息仍按 P7 收束。 |
| `features/image_favorites/type.dart` | 排序枚举、时间范围模型；后续已在原字符串结构内修复滚动范围及完整epoch往返，见[时间范围兼容说明](image_favorites_time_range_compatibility.md)。持久化所有权仍待P4核查。 |
| `features/reader/clipboard_image.dart` | 原生图片转换与剪贴板通道，无页面 context。 |
| `features/reader/gesture_port.dart` | 注入的手势监听契约和坐标值，无 Widget 实现。 |
| `features/reader/image_favorite_swipe.dart` | 经手势端口累计拖动、管理收藏订阅；无具体页面依赖。 |
| `features/reader/image_precache.dart` | 通过传入的 ImageWork 管理解码预取、缓存和帧释放。 |
| `features/reader/layout_detection.dart` | 注入下载与原生工厂的尺寸采样；独立结果和取消生命周期。 |
| `features/reader/reader_mode_labels.dart` | 阅读模式翻译表，无导航和页面依赖。 |
| `features/reader/volume.dart` | 原生音量通道令牌与启停确认适配，无页面 context。 |
| `features/reader/waterfall_controller.dart` | 注入章节读取的加载、取消与预取策略；滚动属于视图。 |
| `features/reader/waterfall_flow.dart` | 章节段、逻辑图片位置与页码映射模型。 |
| `features/search/search_filter.dart` | 按源应用语言过滤条件的纯规则。 |
| `features/search/search_shortcut.dart` | 从页面文件原样迁出的快捷方式身份及 JSON 模型。 |
| `features/search/search_shortcut_manager.dart` | 原样迁出的设置持久化和通知；静态实例及监听生命周期仍待 P4 处理。 |
| `features/settings/sponsor_catalog.dart` | 原样迁出的新旧赞助目录解码与分组模型。 |
| `features/settings/sponsors_loader.dart` | 原样迁出的 HTTP 回退及目录加载；请求资源所有权、错误保留仍待 P4/P7 处理。 |
| `foundation/image_provider/cached_image.dart` | 缩略图加载、并发及绘制提供器适配，无页面依赖。 |
| `foundation/image_provider/read_image.dart` | 首帧 PNG 转换及准确提供器/key 的订阅释放。 |
| `foundation/image_provider/reader_image.dart` | 本地/网络阅读图片与脚本处理的绘制提供器适配。 |
| `foundation/image_provider/reader_image_processing.dart` | JS 图片协议、原始结果及取消钩子的释放，无页面依赖。 |

搜索模型、管理器和赞助目录、加载器的原方法体保持；生产及测试消费者直接导入新文件，没有在旧页面文件添加转发导出。快捷方式菜单、跳转和 sliver 保留在 `search_shortcuts.dart`；赞助页面保留在 `sponsors.dart`。这两个页面文件和错误翻译边界 `source_failure_presentation.dart` 新增为 UI 禁入文件。

The extracted shortcut/catalog models, persistence manager and sponsor fetcher preserve their original bodies. Consumers use the new files directly without forwarding exports. UI rendering and routing stay in their presentation modules. Extraction does not resolve the existing singleton/listener or HTTP ownership concerns.

## 阅读入口与后续分类 / Reader entry and further classification

ReaderEntryLoader通过构造参数注入源详情回调、历史查询和本地查询；ReaderProps随加载服务独立于页面。源不存在才查本地，源请求失败不会静默回退；已有历史、章节和作者/标签映射保持。页面只装配当前管理器并保留初始位置覆盖与展示。EInkRefreshController、样式与请求模型独立，原覆盖层计时与绘制保持；两处旧文件均不转导出迁出类型。本地漫画模型新增local_comics_api.dart业务入口。

The reader entry service receives explicit source/history/local queries. Missing-source fallback, existing history and metadata mapping remain intact; source failures do not trigger local fallback. E-ink policy/controller moves independently of the unchanged overlay. Context/window adapters and UI-bearing aggregates below were inspected directly; classification does not imply removal of their global/lifecycle debt or completion of P8 compatibility cleanup.

| 业务文件 / Business file | 分类依据 / Evidence |
|---|---|
| `features/local_comics/local_comics_api.dart` | Public local-comic model contract; no storage or page exports. |
| `features/local_comics/download.dart` | Actual exports are only download_task, images_download_task and archive_download_task; all are already business-enforced. |
| `features/reader/reader_entry_loader.dart` | Injected source-detail/history/local lookup and ReaderProps; no global managers, Widget or navigation. |
| `features/reader/eink_refresh_controller.dart` | Extracted refresh count, interval/duration normalization and request model; no overlay/timers. |
| `features/reader/display_image_provider.dart` | Painting stream relay and attempt release using the injected ImageWork; no page context. |

| UI文件 / UI file | 分类依据 / Evidence |
|---|---|
| `components/consts.dart` | 160ms animation duration used by presentation. |
| `components/file_save_task.dart` | Original-context/window file-save presentation and error messages. |
| `features/comic_source/source_inspection_task.dart` | Both inspection and selection owner capture BuildContext, route and window registry; UI adapters. |
| `features/favorites/favorites_constants.dart` | Synthetic all-folders UI selection sentinel and responsive width breakpoint; inspected consumers are page/sidebar presentation. |
| `features/reader/image_export_binding.dart` | Context-bound window save, share origin and messages around the independent exporter. |
| `features/settings/settings_task_presenter.dart` | Loading route and messages around an admitted task; original context/window ownership. |
| `foundation/navigation_admission.dart` | InheritedWidget and mounted-context navigation admission. |
| `features/reader/eink_refresh.dart` | Refresh overlay, phase timers and colors after extracting policy/controller. |
| `features/reader/loading.dart` | Reader loading Widget with lookup assembly and initial route/history overrides; data selection moved to loader. |
| `app_runtime/app_runtime.dart` | Aggregate exports interactive init as well as headless entry. |
| `app_shell/app_shell.dart` | Exports auth, home and main pages. |
| `features/comic_details/comic_details.dart` | Exports action button and comic page. |
| `features/comic_source/comic_source.dart` | Compatibility aggregate exports both business API and explicit UI entry; no implementation. |
| `features/comic_source/comic_source_ui.dart` | Exports source page, summary Widget and installation scope. |
| `features/comic_widgets/comic_widgets.dart` | Exports comic list, tile and rating presentation. |
| `features/discovery/discovery.dart` | Exports category, explore and ranking pages. |
| `features/favorites/favorites.dart` | UI-bearing aggregate exports favorites page, actions and display along with API. |
| `features/follow_updates/follow_updates.dart` | UI-bearing aggregate exports follow page and scope along with runtime/API. |
| `features/history/history.dart` | UI-bearing aggregate exports history/stats pages, summary and UI image adapters along with API. |
| `features/image_favorites/image_favorites.dart` | Exports favorite-image page and summary alongside filter types. |
| `features/local_comics/import_export/import_export.dart` | UI-bearing aggregate exports import selection facade and PDF dialog alongside import services. |
| `features/local_comics/local_comics.dart` | UI-bearing aggregate exports local/download pages, summary and image adapter alongside storage. |
| `features/reader/reader.dart` | UI-bearing aggregate exports reader page, loading Widget, comments and scopes; no ReaderProps forwarding. |
| `features/search/search.dart` | UI-bearing aggregate exports search pages, sliver and entry alongside filter rule. |
| `features/settings/settings.dart` | Exports settings pages and form widgets. |
| `features/sync/sync.dart` | UI-bearing aggregate exports archive page, summary and scope alongside controller/transfer. |
| `features/webdav_library/webdav_library.dart` | UI-bearing aggregate exports the InheritedWidget scope alongside business API. |
| `features/comic_source/source_installations_scope.dart` | InheritedWidget grants context access to application-owned installation queue. |
| `features/follow_updates/follow_updates_scope.dart` | InheritedWidget exposes application-owned follow runtime without owning disposal. |
| `features/reader/reader_session_scope.dart` | InheritedWidget provides route completion callback. |
| `features/reader/reader_tap_scope.dart` | InheritedWidget binds tap suppression to the ancestor reader. |
| `features/sync/data_sync_scope.dart` | InheritedWidget exposes the application-owned sync controller. |
| `features/webdav_library/webdav_library_scope.dart` | InheritedWidget exposes application-owned library services. |
| `features/reader/gesture_host.dart` | StatelessWidget composes ReaderState/shell gesture callbacks. |
| `features/reader/shell_host.dart` | StatelessWidget maps ReaderState to shell snapshots and callbacks while preserving child subtree. |
| `features/search/search_entry.dart` | Sliver search entry renders the action and opens SearchPage. |
| `routing/app_links.dart` | App-link event subscription resolves source link and navigates to ComicPage. |
| `routing/handle_text_share.dart` | Native event subscription opens the aggregate search route. |
| `routing/local_reading.dart` | Adapts independent local reading-start policy to root Reader navigation. |
| `routing/page_jump_target.dart` | BuildContext extension maps source search/category targets to concrete routes. |
| `routing/page_replacement.dart` | Mounted/current route replacement through Navigator and AppPageRoute. |
| `routing/settings.dart` | Exports specific settings widgets and page-selection UI functions. |
| `app_runtime/init.dart` | Interactive assembly of tile state/image resolvers, page builder and display/error hooks; debug reload presentation. |
| `foundation/global_state.dart` | State registry and AutomaticGlobalState lifecycle; Pair also holds UI search suggestions. All inspected users are presentation code; existing global-State debt remains P4/P8. |
| `foundation/context.dart` | BuildContext navigation, layout/theme access, share anchor and message dispatch. |
| `foundation/widget_utils.dart` | Widget layout wrappers, TextStyle and Color presentation extensions. |
| `components/window_selection_task.dart` | Context/route/window adapter for independent SelectionOperation plus InheritedWidget registry scope. |

## 继续核查 / Remaining review

- 逐文件阅读基线中的 59 项待审查文件，区分纯展示、导航/平台装配、混合职责及尚未抽离的业务。不能按路径或不可达性批量宣布完成。
- 剩余一个 47 文件的强连通分量包含聚合、导航和页面适配；仍需核实其中是否存在应迁出的业务职责，不以 UI 环可保留为由跳过审查。
- 保留 P3 全配置、P4 服务/资源生命周期、P6 存储写入者与恢复、P7 错误/兼容和 P8 全平台/性能等原方案验收要求。

The remaining 59 files and the retained 47-file component require semantic review. Inventory coverage does not complete P2 or replace configuration, lifecycle, storage, compatibility, CLI, platform or performance acceptance.

## 设置字段与亮度职责 / Settings field and brightness responsibilities

| 文件 | 核实依据与保留事项 |
|---|---|
| `foundation/reader_preference_settings.dart` | 只暴露范围读写实际使用的7个操作，不依赖Appdata或Widget；既有Settings实现此接口，继承、通知和持久化主体不变。 |
| `features/settings/setting_field.dart` | 不可变字段目标与可注入读写服务；保存前捕获JSON值，使用获准执行时的草稿，复用ReaderPreferenceStore范围规则；无生产全局状态或页面依赖。旧可空值和列表仍经明确raw入口处理，未宣称全配置类型化。 |
| `features/reader/brightness_policy.dart` | 原常量、四舍五入/限幅与遮罩透明度规则完整迁移；不合并成保留小数且处理非有限数的NumericPreference，以免改变契约。 |
| `features/settings/setting_components.dart` | 通用表单、弹窗、拖动/增删展示和保存预览；范围/JSON/持久化规则移入字段服务，Appdata仅作装配；列表从服务读取后保留原空标记处理与失效源项。 |
| `features/settings/reader_brightness.dart` | 亮度表单和token预览/监听生命周期；字段目标固定原漫画/源，active写入仍在队列内选范围，具体存储实现只用于装配。 |
| `features/reader/brightness.dart` | 只保留亮度UI预览、遮罩、滑块与面板；布局和绘制主体未改，规则直接导入业务文件，不提供兼容转导出。 |

The settings field service and preference store depend on an injected seven-operation port. Appdata remains the production owner of inheritance, notifications and persistence. The three presentation files are classified only after their storage/policy responsibilities move out. Remaining raw consumers, UI/global ownership and full configuration compatibility remain P3/P4 work.

## 评论解析与组件分类 / Comment parsing and component classification

`foundation/comment_markup.dart`持有不可变文本/标签/图片解析结果，仅依赖已有字符串URL校验。原CSS到TextStyle映射、TextSpan、识别器及图片控件保留在UI，详见[评论标记兼容说明](comment_markup_compatibility.md)。13个组件文件经完整阅读后从待审查移入UI；除评论组件接入独立解析结果外，其余12文件与基线blob相同。

| UI文件 / UI file | 核实依据与保留事项 / Evidence and remaining scope |
|---|---|
| `components/application_update_prompt.dart` | 注入更新服务的InheritedWidget与原页面/窗口弹窗所有者；版本获取仍属独立服务。 |
| `components/button.dart` | 按钮外观、hover/loading呈现、鼠标位置与菜单回调；没有独立数据策略。 |
| `components/code.dart` | TextEditingController、Tab输入、滚动和高亮TextSpan；JS语法表仅用于代码着色，非源脚本解析。 |
| `components/effects.dart` | ClipRRect和BackdropFilter的模糊绘制。 |
| `components/flyout.dart` | 控件坐标、叠层定位、路由和主题；控制器仍持有视图回调，其解绑生命周期待P4审查。 |
| `components/gesture.dart` | InkWell、鼠标返回事件、hover动画等输入适配。 |
| `components/image.dart` | ImageStream到RawImage/CustomPaint的显示适配；ImagePart是此绘制API的裁剪参数，未发现业务消费者。静态尺寸缓存未见填充，clear入口的候选冗余及图像生命周期继续审查。 |
| `components/layout.dart` | Sliver尺寸与列数布局；漫画显示配置仍在UI装配读取，类型化消费属于P3后续。 |
| `components/loading.dart` | State绑定的加载/分页、重试提示和动画；具体loadData由调用者提供，未将其视为无头服务。分页错误及任务所有权仍待P4/P7核实。 |
| `components/pop_up_widget.dart` | PopupRoute、嵌套Navigator、返回手势和浮层Scaffold。 |
| `components/rich_comment_content.dart` | 使用独立解析结果，保留主题映射、识别器生命周期、图片和链接路由。 |
| `components/select.dart` | PopupMenu、chip尺寸测量、选择样式与勾选动画；迟到回调和测量生命周期仍待P4审查。 |
| `components/side_bar.dart` | PopupRoute侧栏、遮罩点击、尺寸/安全区和iOS返回手势。 |

The new business root reaches only comment_markup.dart and the existing string extensions. Existing business/UI protection, acyclic roots and all 57 allowed feature edges remain. The 13 newly classified files are presentation adapters; their classification is not a lifetime or platform acceptance claim. After that batch, 72 files remained pending; the settings review below reduces this to 60. The 47-file SCC still requires semantic review.

## 设置规则与页面分类 / Settings rules and page classification

`foundation/proxy_configuration.dart`持有不可变代理编辑配置、模式及旧字符串编解码；`features/settings/keyword_settings_store.dart`通过已有设置端口与注入队列执行关键词成员增删，不依赖Appdata、Widget或全局reset。业务入口分别仅可达自身，以及自身/reader_preference_settings.dart。关键词页面不能重新引入两个字面量key，包括藏在getter或局部变量中的key。

以下12文件全文核实为UI；仅network/keyword_blocking改变接线，其余10文件与基线`654e68f`的Git blob相同。具体兼容矩阵见[设置规则兼容说明](settings_rules_compatibility.md)。UI分类不代表配置、异步所有权或平台验收完成。

| UI文件 / UI file | 核实依据与保留事项 / Evidence and remaining scope |
|---|---|
| `features/settings/about.dart` | 更新服务的提示宿主、版本/链接和CHANGELOG资源展示；Markdown分支直接生成主题TextSpan/Widget，不是独立内容解析协议。 |
| `features/settings/app.dart` | 缓存/历史设置、文件选择及已有导入导出服务的展示装配；WebDAV表单委托现有配置/连接测试。原始历史保留字段、连接异常和窗口任务所有权仍待P3/P4核查。 |
| `features/settings/appearance.dart` | 强类型主题选项、应用初始化及导航重建回调；没有主题解析或持久化规则。 |
| `features/settings/data_sync_schedule_fields.dart` | 接收SyncConfiguration模式/间隔及回调，仅构建下拉框和说明，不启动调度。 |
| `features/settings/explore_settings.dart` | 强类型页面列表及剩余显示设置表单；枚举已有源以生成翻译选项，不解析源或配置。原始显示字段继续P3。 |
| `features/settings/keyword_blocking.dart` | 列表、文本输入、重复反馈和保存状态/路由；成员规则及键归属迁入注入服务，原Appdata队列在此装配。 |
| `features/settings/local_favorites.dart` | 收藏选项、任务提示与removeInvalid装配；本地存在性回调仅查询已有管理器，实际删除属于业务管理器。原始字段继续P3。 |
| `features/settings/logs.dart` | 已有日志的过滤/格式化/复制/导出展示；未接管日志采集存储。build内ScrollController与菜单迟到回调继续P4。 |
| `features/settings/network.dart` | 代理模型表单、原生校验、保存等待和DNS控制器映射；编解码已迁出。DNS队列保存与引擎重置保持；全局设置装配及请求生命周期继续P4。 |
| `features/settings/reader.dart` | 阅读范围选择、模式相关控件可见性、预览回调及原始脚本编辑；脚本按字符串交给原队列，不执行JS或解析图像规则。原始脚本字段继续P3。 |
| `features/settings/reader_mode.dart` | 阅读模式选项、当前布局说明、范围捕获及检测按钮；有效模式由已有设置对象解析，检测由注入回调执行。 |
| `features/settings/webdav_connection_fields.dart` | 文本控制器集合及输入控件；连接解析/请求/持久化在外部，控制器由创建者释放。 |

The two new business entries are UI-free and have no file cycles. All prior protections and 57 allowed feature edges remain; 24 graph probes reconnecting either entry to these 12 UI files are rejected. `debug.dart` stays pending because its JS execution, timeout, formatting and JSRef release still mix with its view. Remaining scope: 60 files, the 47-file SCC, narrow domain contracts, configuration validation, lifetime/resource ownership and full acceptance.

## 调试执行边界 / Debug evaluation boundary

| 文件 / File | 核实依据与保留事项 / Evidence and remaining scope |
|---|---|
| `features/settings/debug_evaluator.dart` | 注入执行/释放回调，按原规则格式化顶层结果，返回显示期限与实际顶层完成两个Future；结构化失败保留原异常、堆栈及清理诊断。只依赖Dart和operation_failure，不访问Widget、全局引擎或原生资源。 |
| `features/settings/debug_evaluator_runtime.dart` | 显式传入实际JsEngine，复用runOwnedCode和discardJsResult，保留运行时身份与原生图形引用所有权；已开始的执行关闭时为cancelled，新请求被已关闭引擎拒绝仍为failed。无页面和全局实例查找。 |
| `features/settings/debug.dart` | 代码输入、按钮状态、结果展示、保存配置与服务装配；原reload主体不变。执行/格式化/清理规则迁出；迟到诊断使用不捕获State的回调，30秒显示等待和mounted保护保留。证书字段复用NetworkPreferences。 |

执行服务的普通Dart进程探针及原生JS回归通过，原引擎文件blob未变；两个新业务入口接回debug.dart的图探针均被拒绝，全部既有保护及57条特性边保留。完整500文件登记不能代替59项剩余语义审查、47文件SCC与原方案整体验收。

后续`baad85f`基线修复：DebugEvaluator进一步注入异步drain，result保留顶层显示期限，completion独立加入已返回图的嵌套Promise清理。运行时适配区分关闭取消，共享图遍历按身份释放成功/拒绝派生值并保留全部失败。JsEngine类及其后实现未变，公开JS接口不变；原生探针确认completion后引用由1降为0，无需等待引擎关闭。未放入结果图的脚本工作仍不在排空合同内。见[调试执行兼容与资源说明](debug_evaluation_compatibility.md)。

## 导航与输入适配 / Navigation and input adapters

基线`866ccfb`。以下四文件已逐段核实，职责均为UI。分类不宣称全部交互、无障碍或原生平台行为已经验收。

| UI文件 / UI file | 分类依据 / Evidence |
|---|---|
| `components/menu.dart` | 菜单Route和原上下文选择准入、菜单持有者、延迟插入与关闭、焦点/键盘、布局及菜单条目；MenuRouteController直接持有BuildContext/Navigator，属于展示适配而非领域服务。源码blob未改。 |
| `components/navigation_bar.dart` | 导航项、Pane视图、动画、嵌套Navigator、返回入口、NaviObserver路由快照和主视图更新回调；导航历史属于UI，不是漫画业务状态。修复订阅/快照/回调归属和替换路由位置，未修改业务配置、数据库或页面查找协议。 |
| `foundation/app_page_route.dart` | PageRoute缓存、Semantics、平台过渡、原Route侧滑控制器及Widget检测器；位置/速度用于页面过渡，不是阅读位置模型。修复导航手势配对结束和曲线监听释放。 |
| `foundation/edge_back_gesture.dart` | LayoutBuilder/RawGestureDetector布局、边缘区域、方向/宽度归一化、指针竞技场与速度跟踪；均为输入适配，析构时显式取消已接受手势。 |

所有旧业务/UI/成环保护、232个业务入口和57条允许特性边不变。四项业务接回UI的外部图探针被拒绝；修改文件导入集合及47文件SCC未变。剩余55文件与导航环的完整语义审查继续；原生iOS、其他导航/保存准入和全域生命周期仍按原P4/P8验收。见[导航归属兼容说明](navigation_ownership_compatibility.md)。

All four files are UI adapters after complete source review. Their controllers depend on routes, contexts, animation and pointer input rather than domain data. Existing protections remain; classification does not claim full UX/accessibility, native-platform or overall lifecycle acceptance.

## 顶栏与相关组件 / Appbar and related components

| UI文件 / UI file | 分类依据 / Evidence |
|---|---|
| `components/appbar.dart` | Header, tabs, search fields, painting and their controller/field bindings; no persistence or business service. Owned resources now dispose and borrowed-controller listeners replace correctly. |
| `components/scroll.dart` | Viewport physics, nested hover/wheel ownership, scrollbar metrics, drag and painting. Existing blob unchanged; classification does not complete all platform input acceptance. |
| `features/comic_widgets/rating.dart` | Star geometry and pointer-to-rating UI mapping. Existing blob unchanged; configurable rating/invalid input cases remain a separate UI contract audit. |
| `features/reader/chapter_navigation_button.dart` | Presents an existing chapter action with animation, focus/semantics exclusion and safe-area positioning; no chapter loading/storage. Existing blob unchanged. |

Four business-to-UI reconnection probes are rejected. Remaining classification is 51 files; the 47-file SCC is unchanged. See [controller ownership](appbar_controller_compatibility.md).

## 关键词配置与过滤 / Keyword configuration and filtering

| 文件 / File | 分类依据 / Evidence |
|---|---|
| `foundation/keyword_settings_store.dart` | 原业务文件迁移，读取/保存端口注入；成员编辑在原队列准入后读取草稿，批量选择固定输入且可幂等重试。无Appdata、Widget或UI依赖。 |
| `foundation/keyword_filter.dart` | 只接收不可变字符串快照及显式文本/标签，漫画区分大小写，评论忽略大小写；普通Dart进程与旧有效规则逐项对照。 |
| `features/reader/chapter_comments.dart` | 组装既有评论控制器与当前类型化过滤器、展示/输入/视口及原目标请求回调。控制器承接加载、取消、分页、发送和源有效性；除过滤接线外主体未改。 |

原存储文件的业务保护随路径迁移，新增过滤入口的完整闭包无UI/待审查依赖。两项业务接回章节UI探针均失败，57条允许特性边和47文件SCC不变。漫画列表/卡片仍有其他待审查职责；本轮不把它们整体标为UI。见[兼容说明](keyword_filter_compatibility.md)。

## 收藏配置与显示 / Favorite preferences and display

`features/favorites/favorites_display.dart` 全文核实为UI：规则由foundation的Preference拥有，文件只接线当前值、监听设置、绘制菜单及保留原保存/路由/代次归属。Appdata只删除重复默认值，管理器的原始初始化修复/清空回滚保持；不因配置类型化把整个管理器重新分类。

两项业务接回显示UI探针均被拒绝。57条允许特性边和47文件SCC不变；余下49个文件仍需逐一审查。完整兼容边界见[favorite_preferences_compatibility.md](favorite_preferences_compatibility.md)。

## 应用配置与历史清理 / Application settings and retention

`features/history/history_retention_change.dart` 只依赖基础类型配置和显式准入/目标/保存/清理回调，无Widget、全局Appdata或平台句柄。它固定选择与首次清理截止，管理一次操作及其失败重试；原管理器装配连接代次。两个接回设置UI的探针被拒绝，全部原保护和57条特性边保留。

设置页不再导入history聚合UI，退出原SCC；实际剩余46文件，没有新增或扩大环。其余49个待审查文件及导航环的语义收束继续进行。见[应用行为兼容](application_behavior_compatibility.md)。
