# Public-symbol candidates and reachability audit

[JSON](public_symbol_candidates.json)

Date: 2026-10-03. Baseline ed7a2b6 plus this stage in the working tree, including existing user edits. All 378 lib Dart files are reachable from main.dart through imports/exports/parts, including all conditional alternatives. This is potential file reachability, not proof of symbol use.

## Method and limits

The standalone tool/code_audit package uses analyzer 9.0.0 to parse 378 production and 217 tracked test files. It enumerates non-underscore top-level types/functions/aliases, extensions, enum values, fields, methods/accessors and named constructors. Local functions and parameters are not independent public candidates; public-name members of private classes remain included. Parse diagnostics fail the scan.

Of 6071 declarations, 341 have no more same-name production identifier tokens than same-name public declarations. Comments are excluded; test identifiers and exact strings are separate evidence. Calls and tear-offs contribute identifier tokens. Colliding names can hide unused members; operators, overrides, implicit extensions, dynamic dispatch and JS/native callbacks need review. This is not a resolved call graph and does not prove absence of further dead code.

## Classification

| Category | Count | Decision |
|---|---:|---|
| `compatibility_protocol` | 262 | Framework/interface/extension/operator/name protocol; retain |
| `investigate` | 36 | Investigate; do not delete on counts alone |
| `test_evidence` | 42 | Test evidence; retain and review test hooks in P8 |
| `dynamic_entry` | 1 | Runtime entry; retain |

The JSON records file, line, owner, kind, annotations, production/test/string counts, category and reason for every candidate. Remaining investigation targets are listed below:

| Location | Symbol |
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

ComicImporter/ComicExporter may concern legacy .venera-comics compatibility; establish protocol ownership before retirement. A logging string is not a call. JsEngine reset hooks, global-State lookup and filesystem helpers require test-composition, caller ownership and failure-behavior reviews. These items are not claimed cleaned.

## Confirmed removals

- `lib/foundation/extensions/list_extensions.dart`: `getNoBlankList`
- `lib/foundation/extensions/string_extensions.dart`: `nums`, `setValueAt`, `subStringOrNull`
- `lib/foundation/translations.dart`: `tlEN`
- `lib/foundation/widget_utils.dart`: `sliverPaddingAll`, `sliverPaddingVertical`, `s8`, `s24`, `s28`, `s32`, `s36`, `s40`

Removed 13 public extension members and the private _nums helper used only by nums. Searches across source, tests, assets, API docs, examples and patches found declarations only. Extension members are statically bound and cannot be reached by dynamic receivers or JS strings. Other used extensions remain; no replacement implementation was added.

## Runtime/protocol entry checks

- `lib/main.dart`: Flutter/Dart entry; interactive/headless selection remains.
- `lib/foundation/js_pool.dart`: `Isolate.spawn` passes the isolate entry as a function; receive-port callbacks remain.
- `lib/foundation/js_engine.dart`, `assets/init.js`, `doc/api/`: JS host bridge and source APIs remain; exact Dart-name strings alone do not define this protocol.
- `lib/routing/webview.dart`: WebView message callbacks remain.
- `@override`, extension lookup and operator dispatch: retained regardless of low identifier counts.

## Reproduction and validation

```text
cd tool/code_audit
dart pub get --enforce-lockfile
dart run bin/self_check.dart
dart run bin/public_symbols.dart ../.. ../../output/public-symbols.json
dart analyze --fatal-infos
```

The tool emits raw candidates; classifications/removal decisions in the checked-in JSON are reviewed snapshots and are not overwritten automatically. File reachability reuses check_architecture_dependencies.graph_for/reachable. Tool dependencies/lockfile belong only to the standalone package; CI prepares and checks it before repository analysis. Flutter: 1306 passing; analyzer: zero errors/warnings, 65 existing infos. This delivers the P1.3 candidate inventory; investigation items still require follow-up and the overall optimization remains incomplete.

## Follow-up: historical batch executors (2026-10-03)

ComicExporter, ComicImporter and importComics are removed, leaving 33 of 36 investigation items. The historical codec remains separately. See the [retirement review](legacy_comic_archive_audit.en.md). Earlier counts and JSON baseline locations retain their historical meaning.

2026-10-03: All original 36 investigations now have removal evidence (three legacy archive entries, then 33 this stage), with dependent unused chains removed. Final rescan: 6036 declarations/304 candidates, no unmatched new candidates; see investigation_resolution.en.md. Historical counts remain unchanged, without claiming resolved call analysis or zero dead code.
