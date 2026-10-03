# 原待调查符号处理结果

日期：2026-10-03；起点：1de7d4d。原清单 36 项中的旧归档 3 项此前已处理，本阶段核对并删除其余 33 项。历史 JSON 保留原定位/分类，逐项增加 resolution，不把旧清单伪装成当前扫描。

| 定义文件 | 确认无调用后删除的候选 |
|---|---|
| `lib/app_shell/main_page.dart` | `back` |
| `lib/components/loading.dart` | `isFirstLoading`, `haveNextPage` |
| `lib/components/message.dart` | `addOverlay` |
| `lib/components/navigation_bar.dart` | `bottomBarHeight` |
| `lib/components/scroll.dart` | `isMouseScroll` |
| `lib/components/window_frame.dart` | `VirtualWindowFrameInit` |
| `lib/features/comic_source/comic_source_manager.dart` | `reloadSource` |
| `lib/features/comic_source/favorites.dart` | `getFavoriteData` |
| `lib/features/comic_source/tags_translation.dart` | `categoryTextDynamic`, `characterTags` |
| `lib/features/discovery/categories_page.dart` | `ClickTagCallback`, `findComicSourceKey` |
| `lib/features/favorites/favorites_manager.dart` | `getUpdates` |
| `lib/features/history/history_page.dart` | `getDescription` |
| `lib/features/history/image_favorites.dart` | `has` |
| `lib/features/history/image_favorites_models.dart` | `isHasImageKey`, `isAllHasImageKey`, `isAllHasFirstPage` |
| `lib/features/webdav_library/webdav_library_source.dart` | `rootChapterTitle` |
| `lib/foundation/app.dart` | `initComponents` |
| `lib/foundation/cache_manager.dart` | `checkCacheIfRequired` |
| `lib/foundation/extensions/nullable_collection_converters.dart` | `MapOrNull` |
| `lib/foundation/file_system.dart` | `renameX`, `deleteContentsSync`, `forceCreateSync` |
| `lib/foundation/global_state.dart` | `findOrNull` |
| `lib/foundation/image_processing.dart` | `getPixel`, `setPixel` |
| `lib/foundation/image_provider/base_image_provider.dart` | `FileDecoderCallback` |
| `lib/foundation/js_engine.dart` | `debugResetSourceDataBridge`, `debugResetUiMessageHandler` |
| `lib/network/cookie_jar.dart` | `deleteAll` |

每项检查了已跟踪生产/测试 Dart、assets、JS/API 文档、平台与工具代码。除定义文件及审计记录外，唯一出现普通同名单词的是 back/has 的自然语言或其他类型成员，未发现对这两个具体 State/Manager 方法的调用。候选没有覆盖框架接口的方法；不据此删除同类中仍使用的构造器、回调或序列化字段。

重点协议核对：JS 图片处理只分发已声明的 copy/fill/rotate/size 操作，不调用 Dart getPixel/setPixel；PDF 使用 getPixelAtIndex，予以保留。imageKey/ep 等 JSON 字段保留，仅删除无调用的汇总 getter。窗口通过现有 VirtualWindowFrame 装配，不使用旧 Init 包装；启动由 bootstrap_core 的 appdata.init 装配，不使用 App.initComponents。CookieJarSql 未实现必须保留 deleteAll 的外部接口。在线源正常替换仍通过 replaceScript，未删除当前更新入口。

连带清理：_categoryTextDynamic、_replaceLast、isHasFirstPage，以及 OverlayWidgetState.entries/remove 这 5 项只服务已删除入口；保留 toast 实际插入/清理。复扫又确认 translateTagsCategoryToCN、tagsCategoryTranslations 和两张分类映射表组成无调用链，一并移除。三库事务迁移后 batchDeleteHistories 仅剩测试调用，也已移除；测试改为覆盖正在使用的 importStorage + HistoryRepository.removeMany 队列契约。ListOrNull、字符标签主映射、当前缓存检查和 JS 配置入口均保留。

最终复扫：379 个生产文件、221 个测试文件、6036 个公开名称声明和 304 个低引用候选；这 304 项均对应历史框架/协议/测试候选，没有新增未分类项。原 36 项调查已全部处理，但同名计数仍不是解析调用图，剩余候选也不能自动判成死代码。未覆盖的动态拼接名称和未来改动继续受原工具限制约束。

验证：最终全量 Flutter 1339 项通过；分析零 error/warning、63 个 info（原 65 个中的两个来自已删除代码）；结构/75 项业务入口、Python 57 项（3 项平台工具跳过）、Git 依赖和格式通过；工具自检/分析通过。首轮分析发现 orphan import 后已清理，首轮全量通过后又因复扫发现连带代码而运行最终全量。日志 output/investigation-cleanup-{final-full,final-analyze}.log 与 output/public-symbols-after-investigation.json。未新增“证明没有调用”的实现镜像测试，既有运行时/协议回归保留。
