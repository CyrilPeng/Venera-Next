# Resolution of original investigation candidates

Date: 2026-10-03. Baseline: 1de7d4d. Three of the original 36 candidates were resolved with legacy archive retirement; this stage reviews and removes the remaining 33. Historical JSON retains original locations/categories with individual resolutions rather than masquerading as a fresh scan.

| Definition file | Removed after caller review |
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

Reviewed tracked production/test Dart, assets, JS/API docs, platform and tooling references. Outside definitions/audit records, back/has occur as ordinary prose or unrelated members; no calls to the specific State/Manager methods were found. Candidates do not override required framework methods; used constructors, callbacks and serialization fields remain.

Protocol checks: JS image dispatch uses declared copy/fill/rotate/size operations, not Dart getPixel/setPixel. PDF retains getPixelAtIndex. imageKey/ep JSON fields remain; only unused aggregate getters were removed. Window assembly directly uses VirtualWindowFrame; startup uses bootstrap_core's appdata.init. CookieJarSql does not implement an external interface requiring deleteAll. Source replacement still uses replaceScript, preserving active update entry points.

Dependent cleanup: _categoryTextDynamic, _replaceLast, isHasFirstPage and OverlayWidgetState.entries/remove solely served removed entries; live toast insertion/cleanup remains. Rescan exposed the unused translateTagsCategoryToCN/tagsCategoryTranslations/two-map chain, which was removed. batchDeleteHistories had only a test caller after three-database migration; removed it and retained queue coverage through production importStorage + HistoryRepository.removeMany. ListOrNull, primary character translation, active cache checks and JS configuration remain.

Final rescan: 379 production files, 221 test files, 6036 public-name declarations and 304 low-reference candidates. All 304 match historical framework/protocol/test candidates; no unmatched new candidates. The original 36 investigations are resolved, but name counts remain distinct from resolved call graphs and retained candidates are not automatically dead code. Dynamic name construction and future changes remain subject to tool limitations.

Validation: final full Flutter 1339 passed; analyzer zero errors/warnings, 63 infos (two removed-code infos below the prior 65); structure/75 business entries, 57 Python tests (three platform-tool skips), Git dependency/format checks passed; tool self-check/analysis passed. Removed an orphan import after initial analysis; repeated the full suite after rescan exposed dependent code. Logs: output/investigation-cleanup-{final-full,final-analyze}.log and output/public-symbols-after-investigation.json. No implementation-mirroring tests were added to claim absence of callers; runtime/protocol regressions remain.
