# Async BuildContext audit

2026-10-03, local working-tree flutter analyze including existing user edits. Enabling the rule exposed 85 diagnostics; import presentation resolved 21 and comment views resolved 8 and source-page flows resolved 8 and local-library flows resolved 3 and sync window binding resolved 1, and history pages resolved 2, and favorite panels resolved 7, and network favorite pages resolved 9, and application settings resolved 9, and local-favorite settings/image summaries each resolved one, and rich comments resolved one, and detail reactions resolved four, and detail downloads resolved three, and local favorite file import resolved two, and network favorite import resolved one, and debug presentation/local redirect each resolved one, and reader gestures resolved the final two, leaving zero. The rule is now enforced as warning. Other infos fell from 23 to 21 after dead-code cleanup; type/syntax cleanup has now brought strict analysis to zero findings.

| File | Remaining diagnostics |
|---|---:|
| `lib/app_runtime/init.dart` | 0 |
| `lib/components/rich_comment_content.dart` | 0 |
| `lib/features/comic_details/actions.dart` | 0 |
| `lib/features/comic_details/comic_page.dart` | 0 |
| `lib/features/comic_details/favorite.dart` | 0 |
| `lib/features/favorites/favorite_actions.dart` | 0 |
| `lib/features/favorites/network_favorites_page.dart` | 0 |
| `lib/features/image_favorites/image_favorites_summary.dart` | 0 |
| `lib/features/reader/gesture.dart` | 0 |
| `lib/features/settings/app.dart` | 0 |
| `lib/features/settings/local_favorites.dart` | 0 |

Resolution: page-owned work checks the matching context.mounted/State.mounted, including failure/finally/resource cleanup. App-owned work resolves an available current root when presenting UI, without relabelling completed work as failed after an old page disappears. Do not silence findings with global ignores, dynamic casts or unchecked helper functions. The gesture file contains user edits and requires selective staging. Recheck diagnostics and behavior each stage. Logs: output/context-lint-baseline.log and output/history-refresh-final-analyze.log.

Favorite-panel follow-up (2026-10-03): the network section accepts FavoriteData and shares a guarded mutation flow across folder modes. Successful remote work invalidates cache before mounted checks; presentation, navigation and parent callbacks require a mounted owner. Folder errors offer retry, and local folder creation no longer updates a disposed State. Five focused tests pass; logs: output/favorite-lifecycle-{targeted,full,analyze}.log.

Network-favorites follow-up (2026-10-03): folder loading moved out of build, with exceptions and disposed owners handled. Comic/folder deletion shares explicit request and commit callbacks; creation disposes its text controller. Remote success invalidates cache and refreshes a live parent without navigating a dismissed dialog. Comic removal sends the actual folderID. Six focused tests pass; logs: output/network-favorites-{targeted,full,final-analyze}.log.

Application-settings follow-up (2026-10-03): four storage operations share a progress owner that releases routes on failure. Authorization support checks use request generations and exception fallback, and UI checks the matching context.mounted. Sync configuration guards its actual builder context. Five task-presentation tests pass; real biometrics and platform pickers still need platform validation. Logs: output/settings-task-{targeted,final-full,final-analyze}.log.

Favorite settings and summary follow-up (2026-10-03): invalid-favorite cleanup uses SettingsTaskPresenter and only publishes counts to a live page. Chart switching uses a post-layout callback instead of a 20ms timer and checks mounting, latest selection and scroll attachment; summary refresh also rejects stale generations. Three real database/widget tests and five existing task-presentation tests pass. Small fixtures do not validate every >100-item background-isolate race or performance scenario. Logs: output/favorites-summary-{targeted,full,analyze}.log.

Rich-comment follow-up (2026-10-03): link handling captures the original route/navigator and removes only that active root-owned route after an app link opens, never popping a new top route. Inactive owners do not start external fallback. State owns recognizers and releases them on text/dependency changes and disposal; rerendering clears old spans/images. Five widget tests and the full 1363-test suite pass; logs: output/rich-comment-{targeted,full,analyze}.log.

Detail-reaction follow-up (2026-10-03): likes bind to the current comic identity and mounted owner, releasing busy state on failure. Rating receives an explicit submission operation, defaults to the displayed one star, catches errors and ignores results after disposal. Four focused tests cover duplicates, retry, comic replacement and dialog replacement. Three download-path findings remain in actions.dart; this does not complete the detail domain. Logs: output/reaction-lifecycle-{targeted,full,final-analyze}.log.

Detail-download follow-up (2026-10-03): the archive dialog returns only a normal/link selection with fixed downloader/comic-ID inputs and owns list/link requests. Detail actions capture the original comic/source/page and validate mounting and identity before enqueueing; chapter selection uses that same comic. Four dialog tests and three existing archive protocol tests pass. Underlying cancellation, reconnection and resume remain in P6/P7 acceptance. Logs: output/download-dialog-{targeted,full,final-analyze}.log.

Local-favorite dialog follow-up (2026-10-03): creation/import UI receives explicit validation, creation, selection/read and import callbacks; State disposes the text controller. Import deduplicates submissions, permits retry after picker/read/parse errors, preserves drafts on cancellation and does not commit after dismissal. Four tests pass. The remaining favorite_actions finding belongs to network batch import; its commit/cancellation semantics remain open. Logs: output/create-favorite-{targeted,full,analyze}.log.

Network-favorite batch follow-up (2026-10-03): prefetch/paging run in a dedicated RequestScope; route exit immediately cancels waiting/further scheduling, and only complete collection enters a synchronous transaction. Stored StateSetter and delayed close callbacks are gone. Failed/cancelled collection does not commit staged records. Ten focused and full 1385 tests pass; see network_favorite_import.en.md. Underlying source work may still finish; post-commit cache/notification errors remain open.

Local-redirect follow-up (2026-10-03): delayed navigation captures its actual context and checks mounting/request cancellation. replaceWithRootPage replaces only the originating route and rejects covered/disposed pages, with reader inputs/session callback captured first. Debug reload errors resolve a nullable current root context. Three route tests and full 1388 tests pass; logs: output/local-redirect-{targeted,full,final-analyze}.log.

## P5/P8: reader image action lifecycle and async context enforcement (2026-10-03)

- Copy/save share useReaderImage. Missing viewports do not start work; completed reads require a mounted owner and unchanged viewport, image list and chapter. Missing-image/error presentation is guarded; both reading and platform failures are handled. Already started platform operations may finish; this does not cancel OS save/clipboard effects.
- Six focused tests cover inactive owners, late bytes/misses, read failures, platform failures and awaiting completion. All 1394 Windows Flutter tests pass. Analysis has zero errors/warnings and 21 infos; use_build_context_synchronously has zero findings and is enforced as warning. Structure/architecture (77 business entries), Git dependencies, formatting and 63 Python tests (3 existing skips) pass. Logs: output/gesture-image-{targeted,full,analyze,python}.log.
- gesture.dart and CHANGELOG were staged selectively, preserving user edits. P5/P8 and the overall plan remain incomplete: the other 21 infos, reader shell ownership, native behavior, performance and remaining acceptance items still require work.
