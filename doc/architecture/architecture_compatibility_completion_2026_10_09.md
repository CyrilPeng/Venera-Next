# R3 架构与兼容收尾 / Architecture and compatibility

基线为 `e7394f88a35f3990b9ded322c973a3f0dead5b91`。本批按[第 11 节](optimization_plan.zh.md#remaining-work)审查职责、收束实际依赖和迁移消费者；验证原始记录位于 `build/optimization_completion_2026_10_09/r3-*`。分类审查不代替原生生命周期、真实账户或平台验收。

## R3.2 默认实例与真实装配收尾

本组基线为 `fe3dd8939a41e1082988841547f8319de2aace13`，原始证据使用同目录的 `r3b-*` 与独立 helper，未重执行或修改已绑定的 R3.1 产物。P8.1 已关闭，原 52 项为 **36 I / 15 P / 1 U**；R3 技术收尾完成，P8.3 的完整覆盖趋势仍由 R4 验收。

- `HistoryManager.cache` 与 `LocalFavoritesManager.cache` 改为只读 getter，独立 manager 不修改默认实例。保留 getter 是为了核心/导入清理可观察尚未初始化的实例，避免通过 factory 意外初始化；关闭/重开保持原连接生命周期，没有引入新的 reset 或全局 setter。
- `FavoritesScope` 与 `HistoryScope` 在实际应用根装配依赖。收藏视图捕获 `FavoriteStoreBinding`，排队任务复核原实例、连接代数和数据路径；替换 scope 只使原绑定失效，另一个视图的绑定不受影响。视图借用存储，不在卸载时关闭业务所有者；已接受写入由原宿主和存储排空。旧视图任务不能进入替换库。
- 阅读会话固定原历史/图片收藏实例，图片选择同时验证当前视图与捕获的 access。图片收藏页面沿列表、图库和照片导航传 manager，替换显式依赖时移交监听、拒绝旧统计/删除结果；历史摘要导航继续使用其明确传入的历史库。
- `SyncWindowBinding` 接收历史排空 callback，并在关闭开始时捕获它。`FollowUpdateJob` 在一个任务内固定收藏实例，读取、单本更新及最终通知使用同一所有者。`ImportComic` 使用 final 服务依赖，实际导入界面捕获原收藏实例，真实 PDF 与恢复夹具也使用同一服务。
- 基线 **45 个测试文件、200 处生产默认注册表赋值**全部退出。业务夹具使用独立构造；界面夹具通过真实 scope 或 widget 参数注入并驱动替换；完整应用导入/同步夹具使用真实默认实例的关闭/重开。没有以改名全局 setter、删除连接身份检查或放宽门禁代替迁移。

新增两个文件都是 Flutter 视图装配，清单变为 **524 文件：330 业务 / 194 UI / 0 待定，245 业务入口**。57 条允许特性边、原业务文件及入口集合完全不变。最终文件 SCC 为 **42 个 UI/导航成员**：`features/settings/local_favorites.dart` 改为依赖实例 scope 后退出上一组 43 文件环，其余成员不变，无新成员；业务环与业务可达 UI 均为零。最终清单和零注册表赋值复扫保存在 `r3b-audit-final.json`。

验证采用已通过集合加受影响增量：存储/运行时 140 通过且一项预览依赖遗漏；界面集合 617 通过且 10 项失败；修正导入/阅读器依赖后增量 226 全部通过。补充 84 文件集合 881 通过，唯一新夹具缺 Material 宿主；修复后该项单独通过。严格分析最终零诊断，85 个 Dart 文件格式检查无改写，结构/架构门禁通过，49 项架构 Python 测试通过。完整原始失败、源输入与适用范围见[批次报告](completion_batches_2026_10_09.md)；各次计数有重叠，不累加成新增数或声称一次全量通过。未运行本组全量、coverage 或 release。

English: R3.2 retires writable history/favorite registries and all 200 fixture assignments through real instance, view and service composition. Store identity, generation, path and host admission checks remain; accepted work retains its original owner. The two new scopes are UI composition. The inventory is 524/330 business/194 UI/0 pending with 245 entries and unchanged 57 feature edges. The final UI SCC has 42 members after the favorite-settings view leaves it. P8.1 closes (36 I / 15 P / 1 U); R3 technical cleanup is complete while P8.3 trends and R4 acceptance remain open. Related results, repaired deltas and original failures are recorded without claiming a new full suite.

## 依赖清单与 28 个待定文件

完整清单由 **520 文件：326 业务 / 166 UI / 28 待定** 变为 **522 文件：330 业务 / 192 UI / 0 待定**，业务入口 **241 → 245**。原业务文件、入口和显式无环保护没有移除；**57 条允许特性边逐项保持**。新增业务文件是 `local_related_data.dart` 和 `folder_name_validation.dart`；两个历史图片 provider 改为业务分类，并删除自导入及 UI 聚合依赖。

下面 28 个文件已全文审查。UI 的含义包括页面、导航、窗口和插件效果装配，并不表示文件只能包含 `build`。业务策略、SQL、源解析与持久化服务继续处于业务门禁之内。

| 文件（相对 lib） | 职责及依赖判定 |
|---|---|
| app_runtime/sync_window_binding.dart | 将同步状态、退出等待和错误展示绑定到原窗口；同步调度与持久化由注入控制器/服务完成。 |
| components/image_save_binding.dart | 原页面、路由、宿主与图片保存工作的接线；交付和文件所有权由 ImageSaveWork/文件操作持有。 |
| components/settings_save_state.dart | 表单 busy、错误、退出等待及提交后展示；业务写入由已捕获回调提供。 |
| components/window_frame.dart | 桌面窗口框架、焦点、退出屏障和窗口按钮；异步最大化查询返回后复核 mounted。 |
| features/comic_details/actions.dart | 详情按钮、确认、路由和状态发布；调用源 API、下载与收藏服务，不解析 JS 或持有 SQL。 |
| features/comic_details/chapters.dart | 章节展示、点击及下载选择；模型、存储和下载策略由窄入口提供。 |
| features/comic_details/favorite.dart | 收藏面板及操作状态；源读取、收藏事务和提交状态保留业务所有者。 |
| features/comic_source/source_installation_widgets.dart | 安装队列/进度的 Widget 和 Scope；安装、取消及真实结束由 SourceInstallationQueue 持有。 |
| features/comic_widgets/comic_list.dart | 列表分页、错误及 PageStorage 视图快照；注入 loader。快照类型化且不保存进行中的请求状态。 |
| features/comic_widgets/comic_tile.dart | 卡片布局、标签展示和导航；显示过滤使用局部列表，不修改传入 Comic.tags。 |
| features/favorites/favorite_actions.dart | 收藏确认/导出/添加的 UI 适配；文件名输入规则独立，事务、批次和元数据更新调用现有业务服务。 |
| features/favorites/network_favorite_import_dialog.dart | 网络导入弹窗、原宿主准入和结果展示；导入服务承担源读取与单次提交。 |
| features/favorites/read_later.dart | 稍后阅读按钮及刷新；ReadLaterService/manager 承担查询和变更，详情按钮沿用正式 UI 入口。 |
| features/image_favorites/image_favorites_item.dart | 图片收藏条目、菜单及交互；使用实际模型/manager 入口。 |
| features/image_favorites/image_favorites_photo_view.dart | 图片浏览、滑动与选择；图片 provider 和保存工作承担加载/交付。 |
| features/image_favorites/image_favorites_summary.dart | 摘要展示及导航；统计和条目由历史服务提供。 |
| features/local_comics/local_comics_summary.dart | 本地书库摘要和入口菜单；只组装 manager、源 API 与具体目标页。 |
| features/reader/chapters.dart | 章节侧栏、借用暂停与路由释放；章节加载和阅读会话由 controller/session 承担。 |
| features/reader/comic_image.dart | 图像 Widget、绘制、手势及解码显示接线；纯拆页几何规则有独立行为测试。 |
| features/reader/continuous_view.dart | 连续视口布局、滚动及帧调度；内容/页码策略经现有视口与导航协议协作。 |
| features/reader/exit_guard.dart | 退出时焦点、键盘、交互屏障和会话等待，不持有持久化实现。 |
| features/reader/gallery_view.dart | 画廊视口与翻页事件；内容加载、会话和页序规则由业务边界提供。 |
| features/reader/gesture.dart | Flutter 手势识别和动作请求；不直接写入阅读数据。 |
| features/reader/platform_effects.dart | 路由/前台/宿主到平台效果控制器的适配；原生完成与恢复协议留在控制器。 |
| features/reader/scaffold.dart | 阅读展示壳、顶/底栏、侧栏和控件装配；不持有 SQL、源解析或下载队列。 |
| main.dart | 交互应用 composition root、主题与路由；Core/headless 仍有独立入口且不反向到达本文件。 |
| routing/cloudflare.dart | 平台 WebView 导航和验证码交互；修正实际 Linux 分支的过时 Windows 注释。 |
| routing/webview.dart | WebView 插件和页面适配，代理使用类型化配置；Cookie/账户及平台行为仍按 R4 验收。 |

两个 provider 的业务判定：`features/history/history_image_provider.dart` 和 `image_favorites_provider.dart` 只解析图片位置、源章节、缓存键和加载流；不构建页面或导航。后者的图片流在实例构造时注入，原真实章节解析与 read context 保持。

## 原 46 文件 SCC 的语义审查

本批后仍有一个 **43 文件 UI/navigation SCC**，没有新成员；**全部 330 个业务文件均无可达 UI、待定或业务文件环**。特性级的七域聚合 SCC 仍存在，因为它也统计 UI 导航边，不能把它当作业务服务环。

原 SCC 的三个退出成员是 `features/comic_details/chapters.dart` 和 `features/history/{history_image_provider,image_favorites_provider}.dart`。前者改用叶组件/API；后两者移除自导入和页面聚合后被业务门禁覆盖。中间工作区曾有 41 个环成员；结构检查要求 UI 调用者沿用既定聚合入口，修正这些导入后最终为 43 个，不以中间数字替代交付结果。

下表覆盖其余 43 个成员。保留理由是实际页面之间的导航、Widget/State 接线或仍有调用者的 UI 聚合；没有通过把业务服务改名为 UI 规避检查。

| 成员（相对 lib；同组逐项列出） | 环中的边及保留理由 |
|---|---|
| components/rich_comment_content.dart | 富评论点击经 routing/app_links 跳转详情，页面再展示评论；解析规则已在业务文件。 |
| features/comic_details/actions.dart | 打开阅读器、评论、搜索与收藏展示，返回路径由相应页面组成。 |
| features/comic_details/comic_details.dart | 仍被 UI 调用者使用的详情页聚合导出；业务不能导入。 |
| features/comic_details/comic_page.dart | 详情页面装配章节/动作/评论，进入本地阅读与收藏。 |
| features/comic_details/comments_page.dart | 评论页面引用富文本点击适配，形成页面导航环。 |
| features/comic_details/comments_preview.dart | 详情内预览打开完整评论页并复用富文本显示。 |
| features/comic_details/favorite.dart | 收藏展示调用既定 favorites UI 入口，形成与详情动作的交互环。 |
| features/discovery/categories_page.dart | 分类 UI 将 PageJumpTarget 转成页面并打开设置。 |
| features/discovery/discovery.dart | 分类/发现/排行的 UI 聚合导出。 |
| features/discovery/explore_page.dart | 发现列表将源提供的目标交给导航适配并打开设置。 |
| features/favorites/favorites.dart | 收藏页面/动作的 UI 聚合，同时保留 API 导出；业务消费者使用 favorites_api/manager。 |
| features/favorites/favorites_page.dart | 本地/网络页与侧栏的组合宿主。 |
| features/favorites/local_favorites_page.dart | 收藏列表进入详情、历史、本地阅读和阅读器；变更由服务/manager 完成。 |
| features/favorites/read_later.dart | 稍后阅读按钮经正式详情 UI 入口复用 ActionButton，业务查询/写入仍在独立服务。 |
| features/favorites/side_bar.dart | 收藏侧栏打开配置页，配置页回到收藏入口。 |
| features/history/history.dart | 历史页面与摘要的 UI 聚合；模型/provider/manager 有独立路径。 |
| features/history/history_page.dart | 历史列表/筛选/菜单展示引用聚合入口，业务 SQL 在仓储。 |
| features/history/history_summary.dart | 摘要点击进入详情和完整历史页。 |
| features/local_comics/local_comics.dart | 本地书库 UI 聚合；业务使用 local.dart 和其他业务叶入口。 |
| features/local_comics/local_comics_page.dart | 书库列表、选择、导入导出展示与详情/收藏/阅读导航。 |
| features/local_comics/local_comics_summary.dart | 摘要打开书库或详情；不因此将 LocalManager 纳入 UI。 |
| features/reader/chapter_comments.dart | 章节评论 Widget 使用富文本导航，控制器承担请求状态。 |
| features/reader/gesture_host.dart | 将 ReaderState 的实际视口动作适配到手势请求。 |
| features/reader/images_host.dart | 将 ReaderState、图片显示和章节评论组装到页面。 |
| features/reader/loading.dart | 阅读入口准备、错误/加载画面与 Reader 页面交接；读取策略已独立。 |
| features/reader/reader.dart | 阅读页面的 UI 聚合，业务引用 controller/session 等窄路径。 |
| features/reader/reader_page.dart | 阅读页面 composition root；通过上述 UI 宿主组装业务控制器和视图。 |
| features/reader/scaffold.dart | 显示章节评论、设置及导航，生命周期逻辑委托各控制器/宿主。 |
| features/reader/settings_panel.dart | 把阅读偏好编辑嵌入设置页面。 |
| features/reader/shell_host.dart | 将 ReaderState 的展示快照与动作接到 ReaderScaffold。 |
| features/search/aggregated_search_page.dart | 汇总搜索 UI 打开指定源的搜索结果页。 |
| features/search/search.dart | 搜索页、入口、筛选与快捷方式的 UI 聚合。 |
| features/search/search_entry.dart | 搜索输入入口导航到 SearchPage。 |
| features/search/search_page.dart | 输入、历史、快捷方式及聚合/单源结果导航。 |
| features/search/search_result_page.dart | 结果页回到搜索输入/设置，源请求通过 API。 |
| features/search/search_shortcuts.dart | 快捷方式 UI 将业务目标交给 page_jump_target；存储 manager 独立。 |
| features/settings/local_favorites.dart | 收藏设置表单与动作展示，使用真实 manager 与类型化偏好。 |
| features/settings/settings.dart | 仍被设置路由使用的 UI 聚合，不是业务入口。 |
| features/settings/settings_page.dart | 设置分类和对应表单的导航 composition。 |
| routing/app_links.dart | 将真实应用链接和源目标转换为详情页面导航。 |
| routing/local_reading.dart | 把已解析的本地阅读目标转换为 Reader 页面。 |
| routing/page_jump_target.dart | 把源的声明式目标转换为发现/分类/搜索页面。 |
| routing/settings.dart | 只导出指定设置 Widget 给路由消费者。 |

## 跨域接口和兼容边界

| 所有者 | 本批结论 |
|---|---|
| LocalManager / LocalComicRelatedData | 本地管理器只请求迁移历史保存与关联删除两个操作；adapter 固定历史/收藏实例，三库同步 SQL 继续由 local_deletion_storage 承担。排队后复核原收藏连接代数及路径，防止同路径重开后旧删除继续写入。 |
| FavoritesRepository / LocalFavoritesManager | SQL/排序/CRUD 事务在仓储，准入、队列及提交后发布在 manager；ReadLaterService/FavoriteUpdatesService 经仓储/偏好回调工作。manager 不再依赖历史或本地书库页面；源依赖是 comic_source_api，非 parser/UI 聚合。 |
| HistoryManager | 历史与图片收藏仓储、写入队列及 importStorage 持有历史连接；调用者不能借迁移操作绕开队列。源元数据查询保留源 API；封面加载在独立 provider。 |
| 下载与图片 | DownloadTaskStorage 固定原库，ComicImageLoader 固定任务/provider 的实际流；生产 source-image 配置仍由 runtime 显式绑定/解绑，不作为测试替换开关。 |
| 同步 | DataSyncController 经既有 operation/recovery/transport 边界工作；app_runtime 装配实际参与者与生产通知。应用目录锁、数据格式及导入提交协议沿用 R2，无新增万能协调器。 |
| 源仓库 | SourceRepositories 构造时接收借用客户端；load/prepareSave/save 与页面显式传客户端工厂，验证和写入使用同一请求依赖。移除全局 debugCreateDio 和测试专用构造。 |
| 漫画备份 | ComicBackupManager 的 transport、配置读取、归档导入/导出及注册回调均为 final 实例依赖；默认实例不是可替换测试注册表。恢复固定原注册目标，测试使用真实 CBZ importer 时仍等待注册并保留提交诊断。 |
| 本地生命周期 | 删除 debugSkipComicSourceInit/resetForTesting/forTesting。构造依赖仅能绑定一次，independent 不替换默认所有者。成功 dispose 后才释放默认引用；初始化/关闭双失败保留句柄并禁止再次打开。 |

没有修改 SQLite schema、保存 key、源公开 JS 名称、CLI 参数/消息、源 key、归档字段或本地文件布局。PageStorage 改为私有类型快照，只影响进程内视图状态；它深复制页列表，不保存 loading，refresh/dispose 的 generation 阻止旧结果写入新状态。

删除的入口包括 LocalManager 三个测试替换入口、SourceRepositories 测试构造与全局工厂、ImageDownloader 的全局流替换与 reset、ComicBackupManager 的四个可写 static 依赖及 resetOps、6 个 CBZ/详情重复测试转发入口、图片 provider 自导入、旧动态列表 state Map 及过时注释。CBZ 提取/页段/XML/路径测试直接调用实际生产方法，布局测试直接检查 ComicFileSystemLayout；未保留旧名转发。

保留的测试可见入口均有具体目的：JS 引用计数为只读诊断，结果接管/图片回调/限流入口执行真实资源路径；App 路径迁移与 Appdata 读取使用真实迁移或写入队列；下载 resume 与收藏索引 helper 等待真实 Future；拆页几何是实际绘制规则。RHttp 的局部 analyzer 例外用于当前锁定 SDK 的原生完成边界，并有实际生命周期回归；Flutter 自带 debugLabel 等不属于测试开关。

R3.1 提交时仍保留历史/收藏默认注册表替换，因此当时 P8.1 为 P。上述 R3.2 已迁移实际 UI/runtime/service 装配与夹具，并保留重建/替换所有者验证；P8.1 现已关闭。

## 验证与退出判定

原始失败、增量修复、最终联合结果与提交绑定统一记录在[批次报告](completion_batches_2026_10_09.md)。本报告的依赖事实由 `r3-audit-baseline.json` / `r3-audit-final.json` 记录；联合代码输入在 `r3-code-inputs-batch.json`，最终输入/提交另行绑定。结构门禁取消已审定业务 provider/download 到 UI 聚合的错误重定向，图片收藏模型改指向已有 history_api；UI 入口限制和 57 条特性边保持。对应 Python 探针检查业务入口和仍受约束的 UI 入口。本批不运行全量、coverage 或 release。

English: All 28 pending libraries were reviewed by responsibility. The complete inventory contains 522 libraries, 330 business, 192 UI and no pending entries; all 57 allowed feature edges and prior business protections are unchanged. Three members leave the original 46-file SCC; the remaining 43 members are individually explained above as UI composition/navigation. Business reachability is acyclic and cannot reach UI. Local related-data operations, image loaders, source-repository clients and backup dependencies have explicit owners. Typed list snapshots reject retired requests and do not carry pending load flags into replacement states. Six redundant test wrappers now use real production rules or typed layouts. The structure gate no longer redirects reviewed business entries into UI barrels; existing UI entry restrictions remain. At the R3.1 commit, registry replacement remained open under P8.1; the R3.2 section above records its subsequent closure. Classification and local tests do not complete platform, CLI or performance acceptance.
