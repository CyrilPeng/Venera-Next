# Comic-source capability compatibility matrix

Environment: Windows Flutter tests with the real QuickJS library, assets/init.js, synthetic sources and temporary data directories; no network or personal source data. Environments without the native library explicitly skip these tests and cannot inherit this machine's pass claim. This records behavioral scope, not whole-P7 acceptance.

| Capability | Executed behavior | Test evidence | Main remaining boundaries |
|---|---|---|---|
| Account | Quoted/Unicode/backslash login arguments and persisted identity; webview predicate/success callback, cookie validation and logout callback | source_capabilities_test.dart | Real webview/cookie storage/UI; cancellation and save failures |
| Favorites | No request without login; one re-login after expiry; failed re-login/repeated expiry stop; folder list/create/delete | source_capabilities_test.dart | Add/remove favorites, favorite cursors, other re-login branches and structured cancellation |
| Search | Page/cursor callbacks, argument order, next token, tag suggestion and identity after parser reuse | source_capabilities_test.dart; source_lifecycle_test.dart | All option forms and malformed-response matrix |
| Explore | Page/cursor lists, next tokens and arguments | Same as above | Multipart and mixed layouts |
| Category | Legacy/current fixed targets, empty lists, dynamic options with hyphenated labels, category load, cursor ranking and invalid-loader rollback; valid dynamic execution, replacement rollback/commit, removal and engine-close release | source_capabilities_test.dart | Full invalid/asynchronous dynamic-return matrix, random categories, paged ranking and option conditions |
| Comic | Details, malformed data/source errors and source identity | source_lifecycle_test.dart | Like/rating and archive list/download URL bridge execution |
| Images | Chapter images, thumbnails/next token, async image config, sync thumbnail config and identity | source_lifecycle_test.dart | Processing functions, cancellation and full config-error matrix |
| Comments | Comic/chapter lists and pagination, send callbacks and identity | source_lifecycle_test.dart | Vote/like, reply arguments, re-login/cancellation matrix |
| Metadata | Absent optional hooks; existing version/key/install/rollback lifecycle tests | source_lifecycle_test.dart | Link/tag navigation, translations and dynamic settings execution |

Tests are under test/features/comic_source/. Existing normalization tests cover data conversion but do not replace JS bridge execution. See optimization_progress.en.md for stage/full logs. Dynamic categories now use explicit native callback scopes. Next, audit settings/image/UI finalizer ownership and fill remaining capability paths. P7.2 remains partial.
