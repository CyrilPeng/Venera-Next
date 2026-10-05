# Comic-source capability compatibility matrix

2026-10-05 favorite-caller update: ordinary-favorite imports and follow/detail updates retain the originating database generation and check queued cancellation before SQL. Follow metadata and times commit in one transaction. Awaited network-import commit/publication preserve separate outcomes, continue publication after unmount and suppress old receipts after reopen. Evidence comes from real SQLite and controlled caller/widget tests; this does not add a completion claim for real-source or JS-bridge error matrices. See the latest optimization_progress entry for exact scope.

Environment: Windows Flutter tests with the real QuickJS library, assets/init.js, synthetic sources and temporary data directories; no network or personal source data. Environments without the native library explicitly skip these tests and cannot inherit this machine's pass claim. This records behavioral scope, not whole-P7 acceptance.

| Capability | Executed behavior | Test evidence | Main remaining boundaries |
|---|---|---|---|
| Account | Quoted/Unicode/backslash login arguments and persisted identity; webview predicate/success callback, cookie validation and logout callback | source_capabilities_test.dart | Real webview/cookie storage/UI; cancellation and save failures |
| Cookie bridge | Real QuickJS synchronous set/get/delete ordering/returns and synchronous busy/missing-store errors; real SQLite/Dio request/old-response connection ownership | test/foundation/js_cookie_admission_test.dart; test/network/cookie_admission_test.dart | Real WebView collection and account/localStorage transactions, five-platform background/source lifecycle |
| Favorites | No request without login; one re-login after expiry; failed re-login/repeated expiry stop; folder list/create/delete | source_capabilities_test.dart | Add/remove favorites, favorite cursors, other re-login branches and structured cancellation |
| Search | Page/cursor callbacks, argument order, next token, tag suggestion and identity after parser reuse | source_capabilities_test.dart; source_lifecycle_test.dart | All option forms and malformed-response matrix |
| Explore | Page/cursor lists, next tokens and arguments | Same as above | Multipart and mixed layouts |
| Category | Legacy/current fixed targets, empty lists, dynamic options with hyphenated labels, category load, cursor ranking and invalid-loader rollback; valid dynamic execution, replacement rollback/commit, removal and engine-close release | source_capabilities_test.dart | Full invalid/asynchronous dynamic-return matrix, random categories, paged ranking and option conditions |
| Comic | Details, malformed data/source errors and source identity | source_lifecycle_test.dart | Like/rating and archive list/download URL bridge execution |
| Images | Chapter images, thumbnails/next token, async image config, sync thumbnail config and identity | source_lifecycle_test.dart | Processing functions, cancellation and full config-error matrix |
| Comments | Comic/chapter lists and pagination, send callbacks and identity | source_lifecycle_test.dart | Vote/like, reply arguments, re-login/cancellation matrix |
| Metadata | Absent hooks; static settings callbacks, dynamic getter snapshots/independent release, fallback and parse-failure cleanup; page rebuild/collapse/disposal and late/failing/retried callbacks; version/key/install/rollback | source_lifecycle_test.dart | Link/tag navigation, translations and multi-page/source-replacement settings interaction |

Tests are under test/features/comic_source/. Existing normalization tests cover data conversion but do not replace JS bridge execution. See optimization_progress.en.md for stage/full logs. Dynamic categories now use explicit native callback scopes. Image/UI ownership evidence follows; remaining capability paths still need coverage. P7.2 remains partial.

Page evidence: source_settings_widget_test.dart uses production ComicSourcePage and JsCallbackScope with controlled JSInvokable objects to verify destruction counts and page behavior. It complements native tests rather than replacing real JS execution.

Image/UI evidence: reader_image_processing_native_test.dart exercises real processing/cancellation protocols. test/components/js_ui_native_test.dart combines QuickJS and widgets for asynchronous actions/cancellation, input and Navigator unmount, checking native references on engine close. Fourteen controlled js_ui_test.dart cases cover button/back/barrier/unmount, id reuse, retry and late completion. Dialog scopes now explicitly release UI callbacks; normalization compatibility has been removed and direct normalization tests check calls are rejected after explicit release; engine exit with pending Promises remains to audit.
