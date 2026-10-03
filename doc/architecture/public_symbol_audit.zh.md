# 公开符号候选与可达性审查

[JSON](public_symbol_candidates.json)

日期：2026-10-03。基线 ed7a2b6 加本阶段清理后的工作区，包含原有用户修改。378 个 lib Dart 文件均从 main.dart 的 import/export/part 图可达；条件导入的所有分支计入。这证明文件层面的潜在可达性，不证明每个符号都被调用。

## 方法与边界

独立 tool/code_audit 包使用 analyzer 9.0.0 解析 378 个生产文件和 217 个已跟踪测试文件。枚举非下划线命名的顶层类/函数/别名、扩展、枚举值、字段、方法/访问器及命名构造器；不把局部函数和参数作为公开候选，私有类中的公开名称成员仍包含在清单中。解析有诊断时立即失败。

6071 个声明中，341 项的同名生产标识符数量不超过同名公开声明数量，进入候选表。注释不计引用，测试标识符和精确字符串单独记录；普通函数/方法引用和 tear-off 会计入标识符。相同名字会掩盖独立的未用成员；运算符、override、隐式扩展、动态分发、JS/native 回调必须另查。它不是类型解析后的调用图，不能据此证明不存在其他死代码。

## 分类

| Category | Count | 处置 |
|---|---:|---|
| `compatibility_protocol` | 262 | 框架/接口/扩展/运算符或名称协议，保留 |
| `investigate` | 36 | 待调查，不因本次计数而删除 |
| `test_evidence` | 42 | 有测试引用，保留并纳入 P8 测试钩子审查 |
| `dynamic_entry` | 1 | 动态入口，保留 |

JSON 对全部 341 项逐项记录文件、行、所有者、声明种类、注解、生产/测试/字符串计数、分类与理由。以下是待调查项，形成后续工作的明确范围：

| 位置 | Symbol |
|---|---|
| `lib/app_shell/main_page.dart:34` | `_MainPageState.back` |
| `lib/components/loading.dart:280` | `MultiPageLoadingState.isFirstLoading` |
| `lib/components/loading.dart:282` | `MultiPageLoadingState.haveNextPage` |
| `lib/components/message.dart:190` | `OverlayWidgetState.addOverlay` |
| `lib/components/navigation_bar.dart:116` | `NaviPaneState.bottomBarHeight` |
| `lib/components/scroll.dart:54` | `SmoothScrollProvider.isMouseScroll` |
| `lib/components/window_frame.dart:756` | `(top-level/extension).VirtualWindowFrameInit` |
| `lib/features/comic_source/comic_source_manager.dart:163` | `ComicSourceManager.reloadSource` |
| `lib/features/comic_source/favorites.dart:73` | `(top-level/extension).getFavoriteData` |
| `lib/features/comic_source/tags_translation.dart:109` | `(top-level/extension).categoryTextDynamic` |
| `lib/features/comic_source/tags_translation.dart:180` | `(top-level/extension).characterTags` |
| `lib/features/discovery/categories_page.dart:146` | `(top-level/extension).ClickTagCallback` |
| `lib/features/discovery/categories_page.dart:155` | `_CategoryPage.findComicSourceKey` |
| `lib/features/favorites/favorites_manager.dart:973` | `LocalFavoritesManager.getUpdates` |
| `lib/features/history/history_page.dart:349` | `_HistoryPageState.getDescription` |
| `lib/features/history/image_favorites.dart:33` | `ImageFavoriteManager.has` |
| `lib/features/history/image_favorites_models.dart:109` | `ImageFavoritesEp.isHasImageKey` |
| `lib/features/history/image_favorites_models.dart:154` | `ImageFavoritesComic.isAllHasImageKey` |
| `lib/features/history/image_favorites_models.dart:169` | `ImageFavoritesComic.isAllHasFirstPage` |
| `lib/features/local_comics/import_export/comic_export.dart:163` | `(top-level/extension).ComicExporter` |
| `lib/features/local_comics/import_export/comic_import.dart:27` | `(top-level/extension).ComicImporter` |
| `lib/features/local_comics/import_export/comic_import.dart:29` | `ComicImporter.importComics` |
| `lib/features/webdav_library/webdav_library_source.dart:48` | `WebDavLibrarySource.rootChapterTitle` |
| `lib/foundation/app.dart:169` | `_App.initComponents` |
| `lib/foundation/cache_manager.dart:198` | `CacheManager.checkCacheIfRequired` |
| `lib/foundation/extensions/nullable_collection_converters.dart:7` | `(top-level/extension).MapOrNull` |
| `lib/foundation/file_system.dart:126` | `(top-level/extension).renameX` |
| `lib/foundation/file_system.dart:136` | `(top-level/extension).deleteContentsSync` |
| `lib/foundation/file_system.dart:152` | `(top-level/extension).forceCreateSync` |
| `lib/foundation/global_state.dart:19` | `GlobalState.findOrNull` |
| `lib/foundation/image_processing.dart:174` | `Image.getPixel` |
| `lib/foundation/image_processing.dart:188` | `Image.setPixel` |
| `lib/foundation/image_provider/base_image_provider.dart:214` | `(top-level/extension).FileDecoderCallback` |
| `lib/foundation/js_engine.dart:99` | `JsEngine.debugResetSourceDataBridge` |
| `lib/foundation/js_engine.dart:104` | `JsEngine.debugResetUiMessageHandler` |
| `lib/network/cookie_jar.dart:207` | `CookieJarSql.deleteAll` |

ComicImporter/ComicExporter 可能涉及旧 .venera-comics 格式，需先完成协议对照再判断退役；日志字符串不是调用证据。JsEngine reset 钩子、全局 State 查找和文件系统快捷方法需要分别审查测试装配、调用者归属与失败行为。不要把这些待调查项写成“已清理”。

## 本阶段确认删除

- `lib/foundation/extensions/list_extensions.dart`: `getNoBlankList`
- `lib/foundation/extensions/string_extensions.dart`: `nums`, `setValueAt`, `subStringOrNull`
- `lib/foundation/translations.dart`: `tlEN`
- `lib/foundation/widget_utils.dart`: `sliverPaddingAll`, `sliverPaddingVertical`, `s8`, `s24`, `s28`, `s32`, `s36`, `s40`

共 13 个公开扩展成员；同时删除 nums 独占的私有 _nums。使用全库、测试、assets、API 文档、示例和 patch 检索确认只有声明；这些扩展成员为静态绑定，不能由 dynamic 接收者或 JS 字符串直接调用。保留同文件中仍使用的扩展，不新增替代实现。

## 动态/协议入口补充核对

- `lib/main.dart`: Flutter/Dart entry; interactive/headless selection remains.
- `lib/foundation/js_pool.dart`: `Isolate.spawn` passes the isolate entry as a function; receive-port callbacks remain.
- `lib/foundation/js_engine.dart`, `assets/init.js`, `doc/api/`: JS host bridge and source APIs remain; exact Dart-name strings alone do not define this protocol.
- `lib/routing/webview.dart`: WebView message callbacks remain.
- `@override`, extension lookup and operator dispatch: retained regardless of low identifier counts.

## 复现与验证

```text
cd tool/code_audit
dart pub get --enforce-lockfile
dart run bin/self_check.dart
dart run bin/public_symbols.dart ../.. ../../output/public-symbols.json
dart analyze --fatal-infos
```

工具输出原始候选；当前 JSON 的分类及删除结论是本阶段审查快照，不会自动覆盖。文件可达性复用 check_architecture_dependencies.graph_for/reachable。工具依赖与锁文件只属于独立子包，不改变应用依赖；CI 先准备子包并自检，再分析整个仓库。全量 Flutter 1306 项通过，分析零 error/warning、65 个既有 info。该候选清单完成 P1.3 的交付，仍需后续逐项处理待调查项，不代表整个优化计划完成。

## 后续处理：旧批量执行器（2026-10-03）

ComicExporter、ComicImporter、importComics 三项已移除，36 项调查清单剩余 33 项；旧格式模型独立保留。详见 [退役核对](legacy_comic_archive_audit.zh.md)。上文及 JSON 的基线统计保留历史含义。

2026-10-03：原 36 项待调查符号已全部记录删除证据（此前 3 项旧归档、本阶段 33 项），另清理连带无调用链。最终复扫 6036 个声明/304 个候选，无新增未分类候选；详见 investigation_resolution.zh.md。历史候选数不改写，仍不宣称解析调用图或全项目零死代码。
