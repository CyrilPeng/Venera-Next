# Architecture Optimization Execution Record

See the [acceptance inventory](optimization_acceptance.en.md) for current item-level status. Original checklists and dated entries below retain their historical meaning and are not the complete current status.

中文：[架构优化执行记录](optimization_progress.zh.md)

## P0: Tooling and quality baseline (2026-09-30)

- Starting revision: `550fcff`. Existing reader menu locking, long-press auto-reading pause, settings/tests, README and translation changes participate in working-tree tests but are excluded from this phase's commit.
- Flutter tests with fresh coverage: 579 passed, no failures; fresh line coverage 34.62% (10018/28938).
- Analysis after excluding generated `build/` output: no errors/warnings, 24 infos. Two errors and one info originated in generated output.
- Existing Python suite: 44 tests, 3 skipped. Seven additional dependency-checker tests cover conditional/relative/package references, parts, comments/strings, transitive UI exports, new edges and cycle detection.
- CI rejects new feature dependencies. The current aggregate component includes comic_details, favorites, history, local_comics, reader, search and sync. It includes UI navigation and is not proof of a business-only cycle.
- `dependency_baseline.json` records existing edges and UI files. Business entry points will be enrolled as they migrate; none are enrolled yet.
- Local generated logs are under `output/architecture-*.log` and are not committed.

### Pending device validation

Quality baselines and tooling are complete; actual-device performance and five-platform builds remain unverified. Before P5, fix devices, profile/release modes and synthetic fixtures; repeat chapter transitions, seeking and long-image scrolling at least three times and record elapsed/frame times and peak memory. Before P6, measure directory scans, synchronization and imports.

Compare identical devices/fixtures and establish natural variance before choosing regression thresholds. Suite runtime is not UI performance. Other-platform validation requires the corresponding runner/device and remains unverified until executed.

## Later phases

P1 initial cleanup is complete: Channel had test-only consumers and the component barrel had no production consumers. Both and the dedicated Channel tests were removed; retired-path checks prevent reintroduction. Dynamic JS/platform entry points, migrations and packages are retained without evidence for deletion; temporary artifacts are outside this cleanup. The first P2 service/navigation work unit is complete; other domain interfaces will be narrowed with their migrations. P3 is in progress; P4–P8 are pending. Update this record and CHANGELOG for each verified work unit and commit separately while preserving existing local feature changes.

## P2: First service/navigation work unit (2026-09-30)

SourceUpdateService owns checking, downloading, cancellation, deduplication and repository validation. UI owns interaction; headless callers use the service. Tests inject its client factory. The source API is now enrolled in transitive UI checks; the old barrel remains compatible.

LocalComic no longer navigates. A pure policy resolves initial positions and a routing adapter obtains history and opens the reader. Tests explicitly preserve the existing grouped-download selection rule.

Restored the committed lockfile and ran offline dependency resolution with PUB_HOSTED_URL=https://pub.dev and --enforce-lockfile. Initial automatic resolution may have changed the local dependency environment, so the P0 result remains an observation; this locked run is the reproducible comparison point. No lockfile change is committed.

On Windows, prepend build/windows/x64/runner/Release to the test process PATH for the existing sqlite3.dll. Missing-library failures without that path were resolved by rerunning, not counted as passing skips. With locked dependencies and DLL PATH, flutter test --no-pub --coverage passed 577 tests with no skips/failures: six Channel tests removed, four reading-position tests added. Analysis has no errors/warnings and 24 infos; both dependency checks pass. Existing retry, duplicate update, failure and repository scenarios pass.

Device performance and other-platform validation remain pending. Services still depend on existing singletons; P4/P6 will address these. This does not claim all business domains are decoupled.

## P3: Typed reader runtime settings (2026-09-30)

Added immutable ReaderSettings with centralized effective values, defaults, numeric ranges, enum-string validation and legacy long-press compatibility. Manual comic mode remains independent of the other-settings switch; automatic preferences remain device/global scoped. Storage adapters preserve JSON and do not write during resolution. Global preloading/quick collection retain their scopes. Reader state, images, gestures and menus no longer use dynamic getters; CI prevents their return.

Six new behavior tests cover inheritance, modes, legacy values, invalid inputs, immutable snapshots and storage preservation. One new architecture gate test was added. With locked dependencies and Windows DLL PATH, 583 Flutter tests passed without failures/skips; analysis reports no errors/warnings and the existing 24 infos. Python suite: 52 tests, 3 platform skips, no failures.

Only architectural changes were staged in files shared with existing user edits; menu locking, long-press pause and related settings changes remain uncommitted. P3 is not fully complete: form writes, a single source of defaults, and sync/network/appearance configuration remain to migrate before P4.

## P3: Reader forms and write boundary (2026-09-30)

ReaderPreferences now owns reader defaults, validation and slider ranges/steps, shared by initial storage and runtime snapshots. The legacy long-press null default remains for migration. Typed bindings connect switches, selectors, sliders, reading-mode forms and quick brightness writes. Other domains retain compatible controls; existing scopes and integer slider storage are preserved.

Added four store/scope/default tests and one form architecture gate. With locked dependencies and Windows DLL PATH, all 587 Flutter tests passed without skips/failures. Analysis: no errors/warnings, 24 infos. Python: 53 tests, three platform skips, no failures. Existing user feature edits remain outside the commit.

Reader forms/defaults are complete. Sync/network/appearance configuration and further compatibility cleanup remain within P3; P4–P8 and device/platform verification are not complete.

## Download queue write lifecycle fix (2026-09-30)

- P3 regression testing exposed a Windows race between temporary-directory deletion and background persistence after cancellation. Saves now capture the path and snapshot, run in order, and expose completion. Failures reach awaiting callers and are logged without blocking later saves.
- Tests await actual persistence and cover failure recovery and consecutive snapshots. The working tree, including pending settings migration and user edits, passed 592 Flutter tests; analysis reported no errors/warnings and 24 existing infos. This fix is committed separately from settings migration.

## P3: Network and appearance configuration (2026-09-30)

- Extracted shared Preference/PreferenceBinding types while retaining reader scopes. Added global bindings and immutable network/appearance snapshots, shared defaults, DNS filtering, and download concurrency bounds; existing keys and integer storage remain intact.
- Migrated settings forms, proxy, HTTP configuration, downloader and theme consumers. Legacy yellow/cyan colors and device proxy sync exclusions remain supported. Boundary checks reject direct access to migrated keys in these consumers.
- Added four configuration/storage tests and one boundary test. The full working tree passed 592 Flutter tests without failures/skips. Analysis: zero errors/warnings, 24 existing infos. All 54 Python tests completed successfully (three platform skips); structure, architecture and Git dependency checks passed.
- Existing user changes remain separate. Sync configuration in P3, P4–P8, device performance and platform verification remain unfinished.

## P3: App sync configuration (2026-09-30)

- Pure SyncConfiguration/SyncConnection parsing distinguishes empty and malformed connections and retains credential whitespace until the WebDAV boundary. SyncPreferenceStore centralizes configuration, mode, interval, pending and last-attempt access; rollback preserves raw legacy values.
- Service and settings UI use the typed boundary. Previewing malformed settings no longer mutates stored data. Initial transfer, scheduling, persistence and change-generation handling remain in the service. CI checks migrated keys in both settings and implicitData.
- Added three parsing/storage tests; all 595 Flutter tests passed. A subsequently added regression for local edits during failed configuration passed with all 13 schedule tests; the full suite was not repeated for that test-only addition. Analysis: no errors/warnings, 24 existing infos. Python: 55 successful tests (three platform skips); structure and architecture checks passed.
- Core P3 consumers have migrated. Appdata backup/import protocols and unmigrated settings retain raw storage access pending the P8 compatibility audit. P4 follows; device and platform acceptance remain pending.

## P4: Initialization concurrency and failure contract (2026-09-30)

- Init now shares one attempt Future and exposes four lifecycle states. Concurrent initialization/waiters receive the same success or original error. ensureInit still waits for explicit startup; failures remain cached until retryInit. Retry during active/ready work does not duplicate execution.
- Audited all four production ensureInit sites: source repositories and favorites wait for Appdata, the source manager waits for JS, and the local library waits for the source manager. Appdata/JS initialization does not wait back on these managers. Startup error policy and mode separation remain a subsequent unit.
- JS initialization cleans up engine/port resources and propagates failures instead of pretending to be ready. Added three Init tests and one native JS failure/retry test.
- All 600 Flutter tests passed without failures/skips. Analysis: zero errors/warnings, 24 existing infos. Structure, architecture and Git dependency checks passed. Existing user changes remain separate.
- This completes only the initialization-contract unit; core/interactive/headless startup, listener/timer ownership and session requests remain pending in P4.

## P4: Sync startup and window lifecycle (2026-09-30)

- DataSync construction no longer registers listeners, starts timers or touches a window. The runtime explicitly starts it once. Disposal is idempotent, rejects new requests, prevents queued transfers from starting and suppresses late notifications; active transfers finish to avoid interrupting persistence.
- SyncWindowBinding owns the upload-wait/force-exit window interaction, registers/removes its close listener with the widget lifecycle, coalesces repeated close requests and does not exit after unmounting. The interactive entry point supplies the exit action.
- Removed debugDisableWindowCloseHandler and the test-only wait wrapper; tests use waitForUpload. A separate staged viewport-test variant preserves the user's existing edits.
- Added four lifecycle/window tests. All 604 Flutter tests passed on Windows without failures/skips. The two custom-window-button tests explicitly skip other platforms; real platform manual acceptance remains unverified. Analysis: no errors/warnings, 24 existing infos. Structure and architecture checks passed.
- The original startup entry still calls start; core/interactive/headless startup separation follows. Sync dependency injection/instances, other service timers and reader request ownership remain pending.

## P4: Core and startup-mode separation (2026-09-30)

- CoreBootstrap caches startup and orders environment, settings, infrastructure, sources, stores and completion. Source failure prevents dependent stores from waiting indefinitely. Shared bootstrapCore does not mount UI or activate automatic sync, window heartbeat or share navigation. Interactive init retains its entry point and caches startup.
- Paths/settings, cookie/HTTP, OpenCC, JS/sources and database failures stop startup. App/tag translations retain original-text fallback; SAF remains optional with logged errors. Failed startup requires process restart rather than implicitly reopening partially initialized databases. Interactive failure uses the existing top-level logger; headless failure emits a structured error and exits 1.
- Headless source UI explicitly reports unsupported operation without using Navigator or launching UI. Cookie creation accepts the resolved data directory, allowing isolated testing without personal application data.
- Added three orchestration/headless tests, one real Windows core integration test and one boundary test. The real core initialized SQLite, HTTP, JS and cache under a temporary directory without a Widget tree; empty source data did not create an automatic sync instance.
- All 608 Flutter tests passed on Windows without failures/skips. Analysis: no errors/warnings, 24 existing infos. Python: 56 successful tests (three platform skips); structure, architecture and Git dependency checks passed. Native CLI subprocess and other-platform startup checks remain pending; the core native integration test explicitly skips non-Windows.
- Core still imports some legacy domain barrels; transitive UI isolation is not complete. Interactive listener/heartbeat ownership, remaining service instances and reader request ownership continue in P4.

## P4: Interactive event subscriptions and heartbeat (2026-09-30)

- The mounted app owns InteractiveBindings, explicitly starts it and disposes Android link/share subscriptions and Windows heartbeat on unmount. Repeated start is idempotent; partial attach failure cleans up existing subscriptions. App disposal also removes the lifecycle observer and global rebuild callback.
- EventSubscription has two production consumers: links and text sharing. It serializes awaited handling, reports errors and owns disposal. Handlers check lifetime after awaits, dropping buffered events and suppressing late navigation. The global text-share initialization flag is removed.
- Added five behavior tests covering ordering, disposal during awaits, recovery after handler errors, repeated start, timer cancellation, late heartbeat and partial attach failure. Timer tests control the clock boundary without a Widget tree or real waits.
- All 613 Flutter tests passed on Windows without failures/skips. Analysis: zero errors/warnings, 24 existing infos. Structure, architecture and Git dependency checks passed. Real Android link/share and platform heartbeat manual verification remain pending.
- Follow-update/WebDAV timers, cache scanning and other service/request lifetimes remain in P4/P6; this unit does not complete P4.

## P4: Automatic sync scheduling ownership (2026-09-30)

- The mounted app starts/stops BackgroundSync, which owns the 15-minute WebDAV check timer and DataSync scheduling. The static WebDAV timer/start method is removed; initialization no longer activates automatic synchronization.
- DataSync distinguishes stop from dispose: stop suspends scheduling while continuing to observe local changes for pending state and allowing requested transfers to finish. Dispose removes observation and rejects further requests. Restart catches up overdue work; repeated start/stop is idempotent.
- Generations isolate stale timer callbacks, partial startup failure stops automatic synchronization, and core/headless checks also forbid BackgroundSync. Existing WebDAV transfers retain their commit behavior; transfer cancellation was not changed in this unit.
- Added four behavior tests covering stale ticks, restart deduplication, startup cleanup, pending changes from real Appdata saves while stopped, and active transfer completion. All 617 Flutter tests passed on Windows. Analysis: zero errors/warnings, 24 existing infos. Python: 56 successful tests (three platform skips); structure/architecture checks passed.
- DataSync observation and legacy managers still have process-level singleton dependencies, to be injected/instantiated in P6. Follow updates, cache scanning and reader request lifetimes remain unfinished.

## P4/P2: Follow-update service and notification boundary (2026-09-30)

- FollowUpdatesService moved out of the page with injected folder/busy lookup, download waiting, task creation, notification and error handling. FollowUpdateTask exposes only update counts and cancellation. Background checks cancel their own task handle rather than unrelated foreground work. Explicit user-requested disable still cancels active checking globally.
- Separate attempt objects isolate waiting/running/cancelled/restarted checks; old completion cannot clear new work or notify late. The mounted application starts/stops the service, favorites callback and sync listener.
- Page/preview widgets now use ordinary State with explicit domain notification subscription/disposal, removing AutomaticGlobalState, state keys and GlobalState lookup. Multiple previews update together; manual checks and favorites changes use the same notification path.
- Added follow_updates_api.dart for the service/task contract as the second business entry protected by transitive UI checks. Legacy manager/page/runtime barrels remain for compatibility; whole-domain transitive UI isolation is not claimed.
- Added four service tests without global reset hooks and one multi-preview/disposal Widget test. All 622 Flutter tests passed on Windows without failures/skips. Analysis: no errors/warnings, 24 existing infos. Structure/architecture checks passed; the existing aggregate dependency cycle did not grow.
- Real-network manual follow-update checks, cache/reader request lifetimes in P4, and P5–P8 remain unfinished.

## P4/P6: Cache scan and shutdown lifecycle (2026-09-30)

- CacheManager.open takes explicit data/cache paths and a scanner. Construction opens storage without launching asynchronous scanning; the compatibility singleton also resolves paths only once. Runtime explicitly starts the manager-owned scan without blocking UI startup.
- cache_scan returns results only. Applying results uses the owning instance and rechecks tracked file ownership, removing global CacheManager access from scan callbacks. Scanning, reads/writes, eviction and clearing share an ordered queue so stale results cannot overwrite new writes/clears. Write input is copied when queued.
- Dispose rejects new work and drains accepted operations before closing SQLite. Failed operations do not poison later work. Scan failure preserves tracked size and reports the error. File layout/schema remain unchanged; cache tests no longer mutate App paths or global scan/cleanup hooks.
- Replaced two tests with seven instance-based behavior tests covering real scans, error recovery, ordering, draining close, eviction and path isolation. Core integration uses the real disposal API. All 627 Flutter tests passed on Windows without failures/skips. Analysis: no errors/warnings, 24 existing infos; structure/architecture/Git dependency checks passed.
- Cache operations now wait behind an active scan; large-cache first-read latency and throughput require P6 performance validation. Compatibility singleton callers will narrow with their respective domains; reader request ownership in P4 and P5–P8 remain unfinished.

## P4: Chapter request ownership (2026-10-01)

- ReaderImagesState and ContinuousModeState each own a chapter request scope, cancelled and disposed on unmount. Ordinary chapter changes reuse the existing chapter key to recreate state; waterfall chapter requests belong to their view.
- Each chapter load creates a child scope, propagates it to source calls through the Zone, and detaches it on completion. Cancellation releases the caller immediately. Checks after local reads and online responses prevent late recovery callbacks, preserving local-first resolution, stable chapter IDs and missing-file fallback.
- Three new behavioral tests cover pre-cancellation, stalled requests and late callbacks, and independent owners. All 630 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- This unit covers chapter lists only. Entry-page comic details requests, shared image subscriptions, precache listeners and the existing global image cancellation remain pending. P4 and the overall plan are incomplete. Non-cooperative underlying work may continue, but late results are not published.

## P4: Image predownload subscriptions and stalled stream cancellation (2026-10-01)

- Gallery and continuous reader views own ReaderImageDownloads, replacing predownloads that created streams without consuming them. Pending work is deduplicated by image/source/comic/chapter; completion and failure release handles. Disposal rejects new work and waits for owned subscriptions to cancel. Delayed continuous predownloads no longer access context after unmount.
- readImageStream is shared by predownloads and ReaderImageProvider. It races StreamIterator events against cancellation, releasing stalled subscriptions while preserving other consumers. Final bytes and errors also release subscriptions. Custom image-processing Future branches without onCancel now observe the stop signal and check cancellation before publishing results.
- Six new behavioral tests cover shared prefetch/display consumers, deduplication, stalled cancellation, idempotent disposal, retry after failure/completion, progress/final bytes and late events. All 636 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- This unit releases subscriptions only. Decoded prefetch listeners, Flutter pending-cache listeners, the reader's existing global image cancellation and prompt cancellation of underlying shared HTTP work remain pending. Reader exit isolation and P4 are not yet complete.

## P4: Cancellation of shared image requests (2026-10-01)

- SharedRequestStream is extracted from the image module and owns a RequestScope independent of any caller. Obtaining a stream does not start its source; listening does. Only active subscribers retain work. Last release signals cancellation before cancelling the asynchronous source. Factory errors, natural completion and repeated cancellation close once; generator termination errors during cancellation no longer escape unhandled.
- Shared source configuration runs in the independent scope, and HTTP explicitly receives its cancellation token. Cancellation checks guard cache/network results, stream data, cache writes and retries. Cache hits now return immediately, avoiding source resolution and network work after fully consuming cached bytes. The unwrapped entry used by direct downloads retains its existing independent behavior.
- Six new behavioral tests cover lazy start/unlistened handles, caller isolation, termination/factory errors, real stalled local HTTP cancellation, production cache hits and source configuration cancellation. All 642 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- HTTP coverage uses AppDio with the Dio IO adapter and a local HttpServer; native Rhttp end-to-end cancellation still needs integration coverage. Decoded prefetch/pending-cache listeners, reader global image cancellation and entry-page requests remain pending. P4 and the overall plan are incomplete.

## P4: Decoded prefetch and reader exit isolation (2026-10-01)

- Gallery views own ReaderImagePrecache, deduplicating pending decoded prefetches by ReaderImageProvider and retaining release callbacks. Successful images stay attached through frame end; unmount/errors release listeners. The manager explicitly relies on ReaderImageProvider resolving synchronously to itself as the cache key, rather than generalizing to asynchronous-key providers.
- Releasing pending prefetches removes only the matching pending-cache listener while retaining live consumers. Decoded cache entries remain. Flutter releases the final keep-alive handle at frame end, then the underlying subscription is cancelled. ReaderImagesState.dispose no longer calls cancelAllLoadingImages, so exiting a reader does not globally cancel other views' downloads.
- BaseImageProvider uses a narrow completer subclass that suppresses only its internal normal-stop exception. Genuine errors retain their logging/error paths. Received ImageInfo handles are disposed promptly; repeated disposal and frame-end cleanup are idempotent.
- Four new behavioral tests cover deduplication, frame-end cancellation, two prefetch owners sharing with a visible listener, error cleanup, decoded-cache retention and repeated release. All 646 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- Pending cache work retained by Flutter for ordinary displayed images still follows framework cache policy; this unit does not clear the global cache. Entry-page details requests, native Rhttp cancellation verification and remaining P4/P5–P8 tasks are still pending. The overall plan remains incomplete.

## P4: Entry loading and page retry lifecycle (2026-10-01)

- LoadingState merges duplicate initial/retry then/setState paths. Each attempt owns an independent RequestScope cancelled on replacement or unmount. Requests, retry waits and post-load hooks run in that scope and validate attempt identity before committing results. Failed Res values retain the four-attempt budget with 200ms delays; cancellation prevents further retries.
- loadData/onDataLoaded explicitly receive scope, migrating both actual consumers: ReaderWithLoading and ComicPage. Reader details and favorite-folder continuations check cancellation after awaits; local navigation microtasks check validity. Changing comic/source parameters on the same State reloads and cancels the previous attempt.
- Genuine synchronous/asynchronous exceptions are logged and displayed as manually retryable page errors. Late cancelled/stale results cannot overwrite newer content. MultiPageLoadingState is unchanged; its reset/in-flight semantics require separate handling during paginated-domain migration.
- Six new Widget tests cover scope propagation, unmount cancellation, retry replacement, the four-attempt budget, disposal during waits, late post-load hooks and recovery from exceptions. All 652 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- Main reading request entries now have ownership. Native Rhttp integration, other service/pagination lifecycles, P5 reading position/controller/view decomposition and P6–P8 remain pending. Neither P4 nor the overall plan is marked complete.

## P5: Image-number and display-page policy (2026-10-01)

- ReaderPageLayout has no Flutter/global-state dependencies and unifies one-based image/display-page numbers with zero-based, end-exclusive image ranges. It supports single-image covers, grouped pages, incomplete final pages and trailing-comment remapping.
- ReaderState history/max-page/initialization, ReaderImagePerPageHandler orientation remapping, legacy local-order progress recovery and gallery image selection reuse the policy. Duplicate formulas, _calcMaxPage, _adjustPageForImagesPerPageChange and temporary _wasOnCommentsPage state are removed; the mixin's abstract dependencies are reduced.
- Last display/comment pages still record the chapter's last image; other pages record their first image. Loading/empty-list counts and existing remap triggers remain compatible. This unit does not alter single-cover setting-change triggers, persisted history, cross-chapter waterfall mapping or wide-image splitting.
- Four new pure-policy tests check partitioning, inverse mapping and anchor preservation across chapter lengths, 1–5 images per page and layout changes. Existing navigation/slider/automatic-mode targeted tests pass. All 656 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- Explicit reading positions, controller/session extraction and view/scaffold decomposition remain pending in P5. P6–P8 and unfinished platform/performance validation retain their full scope. No phase or overall completion is claimed.

## P5: Chapter coordinates and grouped history (2026-10-01)

- ComicChapterPosition distinguishes source chapter ID, one-based flattened index, group, within-group chapter and group boundaries. ComicChapters.positionAt/chapterIndex centralize conversion between reader and persisted coordinates. Original per-group keys preserve positions when groups share an ID, without relying on merged allChapters key counts.
- ReaderState initialization, grouped-history writes and group boundaries, plus LocalManager legacy page-order migration, reuse the conversions. Repeated group accumulation/subtraction loops are removed. Existing history.ep/group/readEpisode formats and ungrouped behavior remain unchanged; conversion does not rewrite persisted data.
- Four new pure-model tests cover ID order, empty groups, repeated IDs, boundaries, coordinate round trips and invalid indices. Existing natural-sort migration and reading-navigation targeted tests pass. All 660 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- Chapter coordinates still need composition with source image numbers, display pages, wide-image split offsets and cross-chapter viewport positions. ReaderController, view/scaffold decomposition and P6–P8 remain pending. Platform/performance scope is unchanged; P5 and the overall plan are incomplete.

## P5: Reader navigation controller (2026-10-01)

- ReaderController owns page/chapter, pending page, end-page jump flags and navigation generations. Page/chapter counts, loading state, animation policy, viewport and callbacks are injected; it has no Flutter, global settings, logging or storage dependencies. Immutable ReaderNavigationState snapshots are reused until state changes to avoid allocation on every scroll read.
- ReaderNavigationViewport exposes only direct/animated page navigation and chapter navigation. ReaderImageViewController extends it while retaining gesture capabilities. ReaderLocation becomes a transitional forwarding layer; duplicate animation counters/generations and navigation logic are removed. Gallery/waterfall position restoration now sends controller commands; the old pageValue field is removed.
- Page disposal closes the controller, rejecting subsequent commands and late animation notifications. Generation filtering preserves replacement animations, boundary-page repositioning, rapid navigation and viewport-first handling of loaded chapters. Restore commands do not publish history; normal page reports retain the existing onPageChanged path.
- Five controller tests without a Widget tree cover snapshots, command boundaries, stale animation/page reports, chapter adapters and late failures after disposal. Existing navigation and 300-page slider tests pass. All 665 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- The controller owns navigation only. Images/loading/settings remain supplied by the assembly layer, and ReaderLocation forwarding remains. Full image/viewport positions, view/session decomposition, P6–P8 and platform/performance validation remain incomplete.

## P5: Source image positions and slice offsets (2026-10-01)

- ReaderImagePosition distinguishes flattened chapter number, source chapter ID and one-based source image number. WaterfallImageRef stores this position instead of separate ambiguous page/eid/chapter fields. All production consumers use position; flow.imageIndexOf accepts source coordinates and validates chapter ID. Prepending chapters changes only the global viewport-list index.
- History writes first map display pages to source images through ReaderPageLayout, then combine ReaderImagePosition with chapter-coordinate conversion. Existing persisted fields remain; display pages/global list indices are not directly saved. Hit testing still selects the entire source image, so both wide-image halves retain the same source position.
- ReaderImageSlice describes normalized horizontal source regions and vertical display offsets. Painting and source-rectangle helpers reuse slice order, retaining right-half-first, inversion and RTL XOR semantics. Slices are not new history pages, and no viewport-offset persistence is introduced.
- Three new behavioral tests cover stable positions/inverse lookup after prepend, chapter-ID mismatch rejection and slice coverage invariants. Existing waterfall/page-layout/split tests are migrated and pass. All 668 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- P5 still requires views to consume immutable state, image-loading state migration, gallery/continuous/scaffold decomposition, and validation of long-image viewport restoration and fixed-device performance. The full P0–P8 objective remains incomplete.

## P5: Reader view files and image-selection protocol (2026-10-01)

- images.dart shrinks from nearly 2,000 lines to 155, handling chapter loading and view selection only. Gallery moves to gallery_view.dart, shared continuous/waterfall rendering to continuous_view.dart, provider/prefetch helpers to image_view_support.dart, and chapter-swipe indication to chapter_swipe_indicator.dart. Each file retains only used imports.
- ReaderImageViewController adds currentImageRange, returning a zero-based, end-exclusive source-image range. Menu selection uses this protocol instead of GalleryModeState/ContinuousModeState checks, removing its images.dart dependency. Gallery hit-selection uses the same range query.
- Existing seven-mode, cross-chapter, prefetch, automatic-reading, gesture and animation behavior is preserved. images.dart temporarily exports both State types for existing consumers/tests. Continuous and waterfall views still share an adapter, and other ancestor ReaderState access remains to migrate.
- Existing behavioral coverage validates the move; no tests were added merely to assert file relocation. All 668 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass. Only this unit's scaffold protocol changes are staged, preserving original uncommitted menu/automatic-reading edits.
- Loading dependency injection, immutable view inputs, separate waterfall coordination, scaffold components, remaining P5/P6–P8 work and platform/performance validation remain pending.

## P5: Injected chapter access (2026-10-01)

- ChapterImageLoader receives chapter-specific local/online readers, error construction and failure reporting. It owns local-first loading, empty/missing-file fallback and request scopes without accessing global managers, source registries, translation or logging.
- loadReaderChapterImages remains the production adapter: it resolves stable chapter IDs and download availability, then supplies LocalManager/ComicSource access as dependencies. Existing local messages, online Res errors and download records are retained; missing local metadata uses the storage directory as the error-path fallback.
- Cancellation releases waiting callers immediately. Late local FileSystemException results check cancellation before reporting, preventing errors/online work after exit. Non-filesystem failures do not silently fall back; recovery notification requires online success and an active scope.
- Five new policy tests require no Widget tree, database or global reset; existing real-local-library adapter tests remain. All 673 Windows Flutter tests pass; analysis has zero errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- The adapter still connects compatibility singletons, and the controller does not yet own image-loading state. Immutable view inputs, waterfall coordination, scaffold components and remaining P5–P8/platform-performance validation remain pending. The overall goal is incomplete.

## P5: Reader content state and load ownership (2026-10-01)

- ReaderController owns ReaderContentState with copied immutable images, loading and errors. The page exposes read-only forwarding; views no longer duplicate loading/error flags, and navigation reads controller loading state.
- Each ReaderContentLoad owns a RequestScope and can start once. Retry cancels the previous attempt; completion/failure validates identity, so disposing an old view cannot cancel a replacement. Layout preparation remains loading, while loaded waterfall segments activate through replaceChapterImages.
- Four new behavior tests cover stale results, owner isolation, immutable snapshots, preparation, retry and disposal. All 21 targeted and 677 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Views still coordinate loading/layout preparation; content commands do not notify UI independently, preserving batched refresh timing. Immutable view inputs, history/session coordination, waterfall/scaffold separation and remaining phases are unfinished.

## P5: History save scheduling and exit flush (2026-10-01)

- ReaderHistoryWriter injects asynchronous save, synchronous exit flush and error reporting, owning the one-second debounce timer. The page retains coordinate updates and storage adaptation but no longer implements timer/flush ownership. The writer imports no widgets, HistoryManager or global settings.
- Repeated turns reset the deadline; timer state is cleared before a write starts. Disposal synchronously flushes only pending work and is idempotent; accepted storage operations are not duplicated. Synchronous/asynchronous save and flush failures are reported without disabling later saves.
- Four new behavior tests cover debounce/latest progress, exit cancellation, repeated disposal, recovery and post-exit storage errors. All 7 targeted and 681 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Existing history objects, synchronous exit-flush behavior, data format and database queues remain. P6 must still audit ordering between synchronous exit flushes and accepted asynchronous writes. Coordinate adapters, session/platform dependencies, waterfall/scaffold separation and remaining phases continue.

## P5: Waterfall chapter coordination (2026-10-01)

- WaterfallController injects chapter access, ID resolution, change notification and previous-chapter error reporting. It owns bidirectional prefetch deduplication, threshold filling, chapter bounds, next-chapter retry and explicit navigation. It reuses WaterfallChapterFlow behind WaterfallFlowView; views cannot insert/reset chapters through that protocol.
- Each read owns a disposable child RequestScope. Navigation replaces the request generation, cancels old prefetch/navigation and rejects late success/failure. Loaded images are copied into immutable lists; empty chapters keep filling until the threshold or final chapter. Existing retry/log/message error paths remain.
- Continuous views retain prepend offsets, frame scheduling and reading-position publication. Frame callbacks validate revision, preventing old prepend/navigation restoration and stale session-ready callbacks from overriding replacement navigation. Ordinary continuous mode does not prefetch chapters.
- Seven new controller behavior tests cover deduplication, empty chapters, retry, prepend offsets, immutable lists, bidirectional cancellation, navigation replacement, recovery and disposal. All 26 targeted and 688 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Views still obtain settings/positions from ReaderState, and cache marks remain in the existing segment model. Full immutable view inputs, scaffold decomposition, session/platform adapters, P6–P8 and platform/performance acceptance remain unfinished.

## P5: Explicit gallery inputs and interaction boundary (2026-10-01)

- ReaderGalleryData groups chapter content, page layout, direction, comments, group boundaries and interaction settings. It reuses immutable controller images without copying chapters on each build. Gallery navigation receives ReaderController explicitly; ReaderState/root-context, global settings and source lookups are removed.
- images.dart composes configuration/dependencies and uses the page-count policy for comment visibility. Comment content, menu/e-ink refresh, collection, size and image-byte access are injected. The viewport interface lives in reader_viewport.dart with a transitional page export; registration/detachment checks identity, and disposal cancels keyboard-repeat timers.
- Gallery owns its providers/prefetch lifetimes and preserves the legacy current-display-page image-processing argument. Removed unused createReaderImageProviderFromKey, _createImageProvider, precacheReaderImage, unused image-index arguments and the GalleryModeState transitional export. Continuous views retain the remaining helpers.
- Three new widget tests mount without Reader/ReaderScaffold ancestors, covering LTR/RTL/vertical inputs, navigation, updated image ranges, collection callbacks, injected comments and detachment. Existing 25 targeted tests and all 691 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Continuous/waterfall inputs, scaffold, session/platform adapters, P6–P8 and platform/performance acceptance remain. Provider internals still use existing infrastructure adapters; not all reader dependencies are instance-scoped yet.

## P5: Explicit continuous-view dependencies (2026-10-01)

- ReaderContinuousData captures direction, cross-chapter policy, boundaries, splitting, prefetch, speed, margins and interaction settings. Active chapters/images come from injected ReaderController so chapter activation takes effect immediately without waiting for parent rebuilds.
- Continuous/waterfall views no longer locate ReaderState, global settings, sources or cache managers. images.dart injects chapter loading/IDs/titles, layout detection, content readiness, menu/collection/error callbacks, size and image-byte access. WaterfallController retains prefetch and request-generation ownership.
- Gallery and continuous views share entry-level viewport identity registration and byte access. Continuous providers retain source-image numbering and resize behavior; the view owns predownload subscriptions. Removed unused image_view_support.dart and its remaining three ancestor-context helpers.
- Four standalone widget tests cover three ordinary directions and waterfall, updated margins, collection, injected chapter loading, active-content replacement and detachment. Existing 25 targeted and all 695 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Both view types have migrated direct ancestor dependencies, but composition still connects legacy services. Provider infrastructure, scaffold, session/platform adapters, P6–P8 and platform/performance acceptance remain; P5 and the full plan are not complete.

## P5: Bottom bar and reading progress components (2026-10-01)

- progress_bar.dart provides ReaderBottomBar, ReaderProgressSlider and ReaderPageInfo with explicit page/bounds/direction, action widgets and navigation callbacks. They access no ReaderState, settings or business managers; the shell retains chapter/group policy and business-action composition.
- The slider owns and disposes its non-requestable FocusNode, preserving focus forwarding and non-animated navigation. The component defines bottom-bar height and retains comment-page clamping, action layout, safe-area padding, blur and border. Overlay position and abbreviated chapter labels remain shell concerns.
- Existing behavior tests cover the structural move without mirror tests. All 10 targeted tests for 300-page rapid navigation, seven-mode automatic reading and auto-pause passed; all 695 Windows Flutter tests passed. Analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Only this unit's scaffold changes were staged from a HEAD copy; original menu-lock/pause edits remain unstaged. Top menu, brightness/settings, status information, image actions, session/platform adapters, P6–P8 and platform/performance acceptance remain unfinished.

## P5: Clock and battery status lifecycle (2026-10-01)

- ReaderStatusInfo is extracted from scaffold with injected clock/battery readers; the default adapter uses Battery and publishes ReaderBatterySnapshot. Clock and battery share one one-second timer, reads do not overlap within a dependency generation, and outlined text rendering is shared.
- Disposal cancels scheduling; dependency replacement advances the generation and rejects late results/errors. Null means unsupported and stops battery polling while the clock continues. Transient failures retain the previous value and retry on the next tick. Platform Futures cannot be forcibly aborted; the component stops scheduling and ignores invalid results.
- Explicit behavior corrections: an initial 0% is no longer treated as absent hardware, charging icons update even at unchanged charge level, and polling failures no longer escape unhandled. Clock formatting, icon thresholds, outlines and shell placement remain.
- Four injected widget tests cover stalled reads/disposal, recovery, charging/zero level, dependency replacement, unsupported hardware and independent clock updates. All 699 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Only scaffold architecture edits were staged; original menu/pause changes remain unstaged. Native battery behavior still needs device validation. Top menu, settings, image actions, session/platform adapters and P6–P8/performance acceptance remain unfinished.

## P5: Top bar and brightness panel presentation boundary (2026-10-01)

- ReaderTopBar receives comic/chapter titles, action widgets and a back callback without ReaderState, source or settings lookup. Scaffold composes comment/settings/lock actions and visibility, preserving navigation, safe areas and title ellipsis.
- ReaderBrightnessPanel lives beside ReaderBrightnessControl in brightness.dart and accepts values plus toggle/change/end callbacks. The panel owns width/styling/compact controls; preference scope, immediate updates and persistence timing remain in the shell.
- Existing brightness and seven-mode reading/pause tests cover the move. All 12 targeted and 699 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Separate staged versions were generated from HEAD, excluding original menu-lock edits. Original top-bar vertical-padding and minimum-column-size edits moved with the code and remain unstaged in top_bar.dart; other existing edits also remain uncommitted.
- Settings-change dispatch, image actions, session/platform adapters, P6–P8 and device/performance acceptance remain unfinished.

## P5: Image export and selection ownership (2026-10-01)

- ReaderImageExporter injects selection, byte reading, save/share and error reporting, consolidating file detection/naming. ReaderImageSelection captures source/comic/chapter identity, chapter/image numbers and title before reading; completion no longer accesses context for filenames. Existing naming/MIME rules remain.
- Each export owns a child RequestScope. Disposal cancels selection/read waits and suppresses late results; already-open platform operations finish independently, and underlying file Futures cannot be forcibly stopped. Current read/platform errors are reported and later attempts can recover. The unused selectImageToData entry is removed.
- ReaderImageSelectionOverlay owns its entry/waiter, completes replaced selections and removes/completes on disposal. Selection validates viewport, content and chapter identity after awaits, rejecting missing/out-of-range images; collection also checks mounted after selection.
- Five export-policy and two overlay tests were added. Standalone tests exposed fixed-height prompt overflow; applying ui-ux-pro-max flexible-layout guidance enables wrapping and growing height. Dark 375×667 and light 667×375 layouts pass with 2× text and reduced motion. All 706 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Only scaffold architecture edits were staged; original menu/pause and top-bar layout changes remain unstaged. Native save/share interactions were not exercised. Image collection, settings dispatch, session/platform adapters, P6–P8 and device/performance acceptance remain unfinished.

## P5: Reader settings-effect dispatch (2026-10-01)

- settings_effects.dart resolves legacy form string keys into ordered ReaderSettingEffect values without Widget, ReaderState or global settings imports. Fixed keys reuse ReaderPreferences, preserving eInkRefresh/readerBrightness prefixes and final view refresh for unknown keys.
- The shell executes an exhaustive switch and checks mounted before every effect. Mode→gesture rebinding→layout detection→reader refresh and system-UI→shell refresh→reader refresh ordering remain; repeated shell-refresh conditions resolve to one effect.
- Two rule tests cover all registered/future settings, final refresh/no duplicate effects, mode ordering and gesture-only changes avoiding mode/detection work. All 12 targeted and 708 Windows Flutter tests passed; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks passed.
- Only this unit's scaffold changes were staged, preserving original menu/pause edits. String notifications remain a compatibility entry and platform/session effects remain adapters. Image collection, session/platform adapters, P6–P8 and device/performance acceptance continue.

## P5: Image favorite business entry point (2026-10-01)

- ImageFavoriteActions in history injects lookup, save, removal and clock. Cover protection/insertion, chapter-order rejection and toggling have no ReaderState, Widget or global manager dependency; the shell adapts selection, translation, storage and feedback.
- The entry is protected by the business dependency audit. Storage format, notifications and error propagation remain unchanged. Four behavioral tests added; the full Windows Flutter log reports 712 passing tests, analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass.
- Staging excludes original menu/pause edits. The legacy no-op assignment for imported empty chapter IDs is intentionally deferred to a separate fix. Selection snapshots, session/platform adapters, P6–P8 and device/performance acceptance remain outstanding.

## P5: Imported chapter favorite ID fix (2026-10-01)

- Appending a favorite to an imported empty-eid chapter now assigns its resolved source ID and copies existing image identities to match. Previously the comparison expression performed no assignment. Page/key/automatic-cover metadata remains intact; nonempty ID conflicts still reject.
- Two regressions cover identity alignment, lookup/removal, cover protection and unresolved IDs. Seven targeted tests pass; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass. The previous commit's 712-test full suite was not repeated for this localized fix.
- This repairs the existing append path, not a bulk database migration. Untouched legacy records and broader compatibility/transaction review remain P6 work; the overall plan stays in progress.

## P5: Reader session coordination and exit ordering (2026-10-01)

- ReaderSession owns the existing duration tracker and history writer. Content readiness and foreground state jointly gate timing; automatic-reading pause and exit notifications are injected. The page adapts Flutter lifecycle, history fields and storage. The new business entry is audited for transitive UI dependencies.
- Exit synchronously flushes pending progress, drains duration writes, then notifies synchronization once. Repeated disposal shares a Future; late content/lifecycle events are ignored. The page logs close notification errors. Accepted progress writes still belong to storage, so P6 ordering review remains required.
- Four new coordination tests cover initial background/loading interleaving, duplicate readiness, exit draining, late events and write/close failures. Seventeen targeted tests and 718 full Windows Flutter tests pass; analysis has no errors/warnings and 24 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- Original menu/pause edits remain uncommitted. History mapping, window/volume/cache adapters, remaining P5, P6–P8 and device/performance acceptance remain outstanding.

## P5: Memory-cache platform query lifetime (2026-10-01)

- ReaderImageCachePolicy extracts thresholds and query lifetime with injected platform reads, cache writes and logging. Existing 1/2/4 GB thresholds, 100/200/300/500 MB limits and 100 MB exit reset are preserved.
- Late memory results cannot enlarge the cache after exit. Only the newest query applies; exit is idempotent and prevents further reads. Null leaves the limit unchanged; current failures are logged and later attempts may retry. Native Futures are not aborted.
- Four policy tests and all 722 Windows Flutter tests pass; analysis has no errors/warnings and 24 existing infos; structure, architecture and Git dependency checks pass. Changelog and boundaries are updated; original user edits remain uncommitted.
- Cross-reader shared-cache arbitration and physical memory/performance checks remain open, along with volume cancellation/re-listening, window/orientation adapters, remaining P5, P6–P8 and device acceptance.

## P5: Volume navigation and subscription controller (2026-10-01)

- ReaderVolumeController injects events, page/chapter navigation and errors. It owns subscription generations and serialized cancellation; repeated enable reuses the listener, disable/exit immediately invalidates input, and reconnect waits for Dart subscription cancellation. Connection/event failures are reported and explicit enable can retry.
- Removed the ReaderVolumeListener mixin and old VolumeListener. volume.dart retains only the original venera/volume adapter. The page selects Android and preserves previous-chapter-end/next-chapter navigation. The controller is a guarded business entry.
- Added four controller tests and one channel protocol test. The initial Widget fake-clock protocol test stalled; that full run was terminated and the protocol test changed to a normal asynchronous test. It passed independently and the fresh full Windows suite passed all 727 tests. Analysis has no errors/warnings and 23 existing infos (one removed with the old untyped parameter); structure, architecture, Git dependency and 12 architecture-script tests pass.
- Flutter source confirms native listen/cancel acknowledgement is separate from Dart cancellation, with activation errors reported through FlutterError. No native protocol changes, Android device acceptance or concurrent-reader channel verification are claimed. Window/orientation adapters, remaining P5, P6–P8 and platform/performance acceptance remain open; original edits stay uncommitted.

## P5: Window controller and exit restoration (2026-10-01)

- ReaderWindowController injects native window operations, frame visibility, close listeners and navigation. Removed the ReaderWindow mixin and App.rootContext lookup; the page captures WindowFrame and root Navigator during dependency initialization. The controller is protected as a business entry.
- Transitions serialize and same-batch toggles coalesce to the final request. Exit immediately detaches the close listener and rejects new requests, then restores windowed mode after accepted operations. Successful hide→fullscreen→show→frame order is retained. Failures still attempt to show the window; any attempted fullscreen entry requires an explicit exit restoration, with errors logged.
- Five behavioral tests cover binding/disposal, close navigation, ordering, in-flight exit, rapid toggles and failures. All 732 Windows Flutter tests pass; analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass. Original edits remain uncommitted.
- Native operations cannot be cancelled. Real desktop interaction, shared-window arbitration across readers, orientation adapters, remaining P5, P6–P8 and device/performance acceptance remain outstanding.

## P5: Orientation ownership and application scope (2026-10-01)

- ReaderOrientationCoordinator owns plain handles instead of a static Widget State list. Only the top handle can cycle; releasing it restores the underlying lock, and releasing the last returns to system policy. Scopes share no state and disposed scopes cannot acquire or reactivate handles.
- ReaderOrientationScope owns the coordinator outside the application Navigator. Main and test harnesses explicitly install it; widgets acquire through an inherited provider. DeviceOrientation conversion and error logging remain in orientation.dart; the coordinator is a guarded business entry.
- System→portrait→landscape cycling, Android-only activation and immediate platform request issue order are preserved. Pending native Futures do not delay release. Three new coordinator tests and eleven existing Widget/channel tests pass; the full Windows suite passes 735 tests. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- Only scope wiring is staged in the already modified automatic-reading test. Original edits remain uncommitted. Physical rotation, other shared-platform ownership, remaining P5, P6–P8 and device/performance acceptance remain open.

## P5: Navigation compatibility exit (2026-10-01)

- Removed ReaderLocation, whose only consumers were the page and tests. ReaderState assembles ReaderController directly and uses preferences for animation settings; unused abstract contracts and the enablePageAnimation wrapper are gone.
- reader_page.dart no longer re-exports ReaderImageViewController; images.dart no longer re-exports ContinuousModeState. Callers import the protocol or concrete view directly. The page retains UI navigation adapters; ReaderController is guarded as a business entry.
- The four existing navigation tests now use ReaderController/ReaderNavigationViewport directly, inject/assert errors and dispose controllers without page/ComicType/global Log dependencies. Fifteen targeted and all 735 Windows Flutter tests pass; analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- Only import migration is staged in the modified automatic-reading test. Original edits remain uncommitted. Further UI adapter reduction, layout/history mapping, shared resource ownership, remaining P5, P6–P8 and platform/performance acceptance remain open.

## P5/P6: History model entry and reader progress mapping (2026-10-01)

- Extracted History from history_manager.dart into history_model.dart; its class body is verified identical. history_api.dart exposes data without manager/page exports, while history.dart retains its public model export. Direct manager-file model consumers migrate with no new compatibility re-export.
- applyReaderHistoryProgress owns display-to-source page mapping, expanded-to-grouped chapter coordinates, read keys and timestamp updates using ReaderPageLayout and ComicChapters.positionAt. The page retains loading guards and session scheduling. Both business entries are dependency-guarded.
- Three new tests cover repeated source IDs across groups, final/comment pages, retained fields and empty content. Four targeted and all 738 Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass. Original edits remain uncommitted.
- Existing empty-content page zero and ungrouped updates retaining group are preserved; no schema changes. The model still has legacy fromMap/fromRow and display descriptions. Row/query separation, persistence ordering, remaining P5–P8 and device/performance acceptance remain incomplete.

## P6: History row mapping and write repository (2026-10-01)

- History no longer imports SQLite or exposes fromRow; an explicit field constructor supports historyFromRow. The mapper preserves column names, comma-separated read-key filtering/deduplication, groups and duration rounding. All row consumers migrate directly.
- HistoryRepository uses a caller-owned Database for progress/duration writes and BEGIN IMMEDIATE transactions. All four SQL statements are verified identical, preserving id/type updates, fallback inserts and rollback. The manager retains connections/migrations, isolates, queue, cache and notifications; schema and asynchronous ordering are unchanged.
- Three in-memory SQLite tests cover legacy row values, groups/nulls/rounding, same IDs across types, duration preservation and trigger-induced rollback/recovery. Eleven targeted tests including existing migration/legacy-table coverage and all 741 Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- Both storage modules are guarded business entries; original edits remain uncommitted. Queries/deletes/migrations still need repository migration; queued snapshots versus synchronous exit write ordering, remaining P5–P8 and platform/performance acceptance remain open.

## P6: History query, deletion and initialization consolidation (2026-10-01)

- HistoryRepository owns table creation/legacy field migration, identity lookup, all/recent/duration lists, statistics, ID enumeration and deletion. HistoryManager no longer selects/executes SQL directly; it retains connection lifetime, async scheduling, cache, notifications and source refresh.
- Favorite predicates run inside the original BEGIN TRANSACTION; batch failures roll back. Retention cutoff remains manager-computed with strict less-than comparison, recent results stay limited to 20, and duration ranking preserves duration/time descending. Primary keys, migration strategy and the existing ID-only cache behavior are unchanged.
- Three added repository integration tests cover ranking/statistics/retention boundaries, typed identity deletion, predicate/trigger rollback, missing legacy columns and repeated initialization. Fourteen targeted and all 744 Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and boundaries are updated; original edits remain uncommitted. Cache identity, async write snapshots/ordering, favorites/local-library/WebDAV/sync decomposition, remaining P5–P8 and platform/performance acceptance remain outstanding.

## P6: History cache source identity fix (2026-10-01)

- HistoryCache owns typed identity guards and recent writes, matching (id, type) to prevent cross-source cache hits. The identity index is bucketed by ID; each write queries only that ID and examines at most ten recent entries, avoiding full-table/full-index scans.
- Supports replacement under the current id-only primary key and coexistence under legacy compound identity tables without schema changes. Refresh removes absent identities, close clears the cache and lookup validates mutable model identity. Ten-entry write-order eviction and asynchronous write ordering remain unchanged.
- Three isolated SQLite/cache tests cover dual sources, deletion refresh, primary-key replacement, reload, eviction and mutated identities. Seventeen targeted tests and the final 747-test Windows suite pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- The cache is a guarded business entry; unused ID-only fields are removed and original edits remain uncommitted. The existing id-only schema still cannot retain both sources for one ID; this fix aligns cache with actual storage. Async snapshots/ordering and remaining P5–P8/platform-performance acceptance remain open.

## P6: Asynchronous write copies and lifetime ownership (2026-10-01)

- History.copy detaches all fields and read keys. Progress/duration APIs capture the copy, database path and generation when submitted, preventing later caller mutation from changing queued values. Duration completion updates the caller only if its identity still matches.
- Cache completion reloads actual persisted data instead of caching unsubmitted caller changes. Only the current initialized generation caches/notifies. Closing invalidates callbacks; reopening cannot redirect accepted writes to another database. Old operations may still finish on their captured database and are not cancelled.
- Added one copy test and strengthened existing queue/drain tests for field/set mutation, duration identity changes, cross-database reopen and suppressed old notifications. The initial targeted suite passed 18 tests; the final full Windows suite including lifetime assertions passed 748. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog/boundaries are updated and original edits remain uncommitted. Copies remain privately owned mutable models, not a full immutable-model migration. Synchronous exit writes versus already-started isolate writes still need ordering work; P6 and remaining P5–P8/platform-performance acceptance are incomplete.

## P5/P6: Drain progress before exit synchronization (2026-10-01)

- ReaderHistoryWriter tracks every unfinished save, immediately invokes a pending exit flush, accepts its FutureOr result and drains all accepted operations. Repeated disposal returns the same Future without duplicate writes or renewed scheduling.
- ReaderSession starts progress disposal and stops duration timing together, then waits for both before notifying sync once. Progress failures are reported and drained. The existing synchronous exit-storage adapter remains; this unit does not resolve synchronous/asynchronous database write races or change final desktop shutdown behavior.
- Two behavior tests cover multiple pending saves, reverse completion, asynchronous flush, repeated disposal, duration completing first and progress failure. All 10 targeted and 750 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and boundary documentation are updated; original user edits remain uncommitted. Next: unify history write/delete ordering and callers requiring durable completion, including desktop shutdown draining. Remaining P5–P8 and device/performance acceptance are incomplete.

## P6: Order history mutations and drain window shutdown (2026-10-01)

- Replace the public addHistoryAsync/synchronous addHistory pair with asynchronous addHistory. Progress, duration, individual/batch deletes and retention/all/unfavorited cleanup share the manager queue with isolate-owned connections. Failures are logged and propagated without poisoning later tasks; waitForAsyncWrites also drains writes accepted during the wait. Batch and favorite identities are captured at submission.
- ReaderHistoryWriter removes the separate flush callback; delayed and exit saves use the same asynchronous path. Import, cover/info refresh and local page-order migration await persistence. Local deletion no longer skips history that has not yet persisted; ordinary UI deletions submit immediately and refresh on storage completion notifications.
- WindowFrame runs close guards before exit tasks in reverse registration order and accepts unfinished saves from unmounted readers. SyncWindowBinding drains history and uploads after sessions. Exit is invoked once, native window close is intercepted at desktop startup and routed through a mounted listener, and explicit forced shutdown remains available.
- Six new SQLite manager tests and four window tests cover ordered updates/deletes, final progress and preserved duration, cleanup snapshots, failure recovery, listener-submitted work, database reopen, mounted/detached sessions, repeated/forced close and native events. The targeted suite passed 32 tests, then the native-event addition passed all six window tests. Final full Windows suite: 760 passing. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Initial import-placement and runtime-entrypoint issues were fixed and checks rerun. Changelog and bilingual boundary docs are updated, preserving original user edits. Actual platform window behavior, system shutdown/macOS application Quit and forced-termination durability are not proven here. Metadata/progress separation, remaining P5–P8 and device/performance acceptance remain open.

## P6: Separate history metadata from progress (2026-10-01)

- HistoryRepository.updateMetadata updates only supplied title/subtitle/cover fields for the complete source identity and never inserts missing rows. Empty strings clear fields; omitted fields remain unchanged. Ordinary progress writes preserve existing metadata and cumulative duration, preventing overwrites in both completion orders; new rows retain full initialization data.
- Capture HistoryManager.metadataUpdaterFor before network requests to bind identity, path and generation. Late responses cannot follow caller identity mutation or target a reopened database. Metadata shares the typed mutation queue and persisted cache reload. Source refresh removes its repeated fromMap reconstruction; cover resolution uses a partial update and fixed download identity.
- importHistory explicitly updates progress and metadata within one transaction, migrating the import caller while preserving the previous duration import policy and schema. Metadata failure rolls back the preceding progress update.
- Three manager and two repository tests cover reading during a request, later progress saves, identity mutation, deletion/reopen, import duration preservation, source isolation, empty/omitted fields and rollback. The full Windows suite passes 765 tests. After null-aware syntax lint cleanup, all 29 targeted tests pass again. Final analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and bilingual boundaries are updated and original edits remain uncommitted. This does not version deletion/recreation within one database or arbitrate competing metadata requests. Model presentation/fromMap, favorites/local-library/WebDAV/sync decomposition and remaining P5–P8/platform-performance acceptance remain open.

## P6: Separate favorite models and SQLite row decoding (2026-10-01)

- Move FavoriteItem, FavoriteItemWithFolderInfo, FavoriteItemWithUpdateInfo and timestamp formatting to favorite_models.dart. favorites_api.dart exports only models; favorites.dart retains its aggregate entry. Same-feature callers relying on implicit manager-file model exports now import the models explicitly.
- Remove FavoriteItem.fromRow; favoriteItemFromRow centralizes twelve SQLite read sites. FavoriteItem.withTime accepts stored timestamps verbatim without parsing or regeneration. Model bodies were compared byte-for-byte apart from the explicit storage-constructor replacement.
- Three compatibility tests cover raw timestamps, removal of only the first empty tag, duplicate tags, legacy JSON source mapping/target fallback, timestamp truncation and export fields. All 12 targeted and 768 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure/architecture/Git dependency checks, 12 architecture-script tests and two structure-script tests pass.
- The data entry and row mapper are guarded business entries, and cross-feature model imports must use favorites_api. Changelog/bilingual boundaries are updated without committing original edits. Global display-setting reads and derived-model timestamp/shared-list behavior remain unchanged. Favorite SQL/cache/follow-update decomposition, local-library/WebDAV/sync and remaining P5–P8/device-performance acceptance remain open.

## P6: Basic favorite query repository (2026-10-01)

- Add FavoritesRepository on a caller-owned connection for folder ordering, counts/order bounds, folder contents, deduplicated/per-folder aggregates, identity lookup and containing folders. The manager retains connections/isolates, caches and notifications. Synchronous and asynchronous lists share query implementations; findWithModel delegates to find.
- Batch-load folder ordering instead of querying each folder, preserving default zero, first duplicate row, metadata-table exclusions and comparison semantics. Ignore orphan/invalid folder names in ordering rows. Read identifiers escape quotes while IDs/types remain bound parameters. Aggregation keeps the first complete identity by folder order; per-folder views retain copies.
- Three in-memory SQLite tests and one manager/isolate equivalence test cover legacy ordering, empty/quoted folders, source identity, bound input, aggregation and raw timestamps. All 13 targeted and 772 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency and 12 architecture-script tests pass.
- The repository is a guarded business entry; changelog/bilingual boundaries are updated without committing original edits. Writes/transactions, initialization, search/follow-update queries, global identity cache and five-platform performance remain pending, along with remaining P5–P8/device acceptance.

## P6: Consolidate favorite move/copy transactions (2026-10-01)

- FavoritesRepository owns single moves and batch moves/copies, sharing escaped identifiers and transfer SQL. Transactions cover order lookup, insertion, source removal and commit, with rollback on failure. Single moves now include the previously missing transaction, preventing destination copies after source-deletion failure.
- Preserve single-move conflict behavior (leave source intact) and prepend ordering. Batches retain destination records, append in input order and remove moved source records; duplicates still advance ordering. Same-folder batch moves/copies now perform no writes or notifications, preventing self-deletion.
- The manager retains folder validation, error logs, counts/identity cache, follow-update refresh and notifications, updating these only after transaction success. Transfers preserve the existing eight copied fields without expanding follow-update/translated-tag policy.
- Five repository tests and one manager test cover duplicate/order semantics, single and partial-batch rollback, successful retry, same-folder protection and cache/notification behavior on failure. All 19 targeted and 778 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and bilingual boundaries are updated without committing original user edits. Add/update/other deletion operations, initialization/search/follow-update SQL, cross-domain decomposition and remaining P5–P8/five-platform-performance acceptance remain open.

## P6: Favorite insertion and field-update repository (2026-10-01)

- Move favorite insertion, folder reordering, tag and information-update SQL into FavoritesRepository. The manager supplies translated tags and front/end/explicit placement while retaining caches, follow-update state and notifications.
- Duplicate checks, order calculation, insertion and optional update-time writes now share a transaction, preventing partial records when the final update fails. Legacy tables without last_update_time still skip it. Folder reordering is atomic and rolls back earlier rows on failure.
- Bind tag values to fix apostrophe-related SQL errors while preserving the existing ID-only cross-source semantics. Information updates continue to affect only name/author/cover/tags, preserving time, order and translated-tag behavior.
- Four SQLite regressions cover explicit/front/end placement, duplicates, legacy columns, optional-time rollback/retry, atomic reorder and quoted tags/field preservation. All 23 targeted and 782 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and bilingual boundaries are updated without committing original edits. Deletion, initialization, search/follow-update storage, cross-domain decomposition and remaining P5–P8/platform-performance acceptance remain open; neither the favorite repository nor P6 is complete.

## P6: Favorite deletion transactions and shared-cover protection (2026-10-01)

- Move single/batch/cross-folder record deletion into FavoritesRepository, deduplicating requests and returning actual removed identities per folder. The manager updates counts/references after commit; missing rows no longer decrement caches or notify.
- Cover cleanup now follows commit and checks all remaining folder references, preserving covers on rollback and while another folder still uses them. Synchronous file-removal failures are logged separately while committed state and notifications proceed; filesystem work is not treated as part of SQL rollback.
- Folder DROP and folder_order cleanup share a repository transaction, restoring the table if cleanup fails. The manager retains settings/follow-update notifications; whole-database clearing, folder-level cover collection and folder_sync cleanup are unchanged.
- Two repository tests and one manager test cover cross-folder rollback, actual/duplicate/missing identities, source isolation, DROP rollback, cache/notification consistency and shared-cover lifetime. All 26 targeted and 785 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog/bilingual boundaries are updated without committing original edits. Initialization/folder metadata/whole-database clearing, ordering/search/follow-update storage, other-domain decomposition and remaining P5–P8/platform-performance acceptance remain pending.

## P6: Favorite folder and network-link metadata (2026-10-01)

- FavoritesRepository owns folder creation/rename and network-link writes, exact matching and lookup. The manager retains name validation, preferences/caches and notifications. Creation initializes counts before notifying so listeners see consistent state.
- Rename changes the physical table, folder_order and folder_sync within one transaction, without premature manager preference/count changes. Folder deletion now clears folder_sync atomically, preventing a recreated name from inheriting an old network link.
- Three repository tests and one manager test cover link replacement/exact matching, order preservation, metadata failure rollback for rename/delete, retry, recreation, retained preferences and creation notification ordering. All 30 targeted and 789 full Windows Flutter tests pass. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog and bilingual boundary/progress docs are updated without committing original edits. Initialization/legacy migrations, whole-database clearing, ordering/search/follow-update storage, other-domain decomposition and remaining P5–P8/five-platform-performance acceptance remain incomplete.

## P6: Favorite schema initialization and legacy-column migration (2026-10-01)

- FavoritesRepository owns the two folder metadata tables, translated-tag column/backfill migration and three follow-update columns. The manager retains default-folder selection, preference fallback, translation and cache refresh; storage does not read global settings.
- Fix the early break on an already-migrated translated-tag column: every legacy folder is checked. Missing columns and backfill share a transaction, rolling back earlier folders on failure and preserving existing columns. Tracking-column additions and optional flag reset are atomic, retaining stored timestamps and clearData=false state.
- Three SQLite regressions cover repeated initialization, mixed-version folders, cross-folder schema/data rollback, retry and failed tracking reset. The full Windows suite passes 792 tests; after a braces-lint correction all 33 targeted tests pass again. Final analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks pass.
- Changelog/bilingual boundaries are updated without committing original edits. Connection initialization reuse/recovery, whole-database clearing, ordering/search/tracking data operations, other domains and remaining P5–P8/five-platform-performance acceptance remain incomplete.

## P6: Favorite ordering and search repository (2026-10-01)

- Read-later limited reads, favorite record reordering and folder/global search now use FavoritesRepository, removing duplicated matching logic from the manager. Reordering uses full identities and one transaction; failures roll back before manager logging, with no success notification.
- Preserved first-token LIKE/wildcard/translated-tag behavior, case-sensitive secondary matching against original fields, first-identity deduplication and folder-level cutoff above 200 candidates before secondary filtering. Result order and product semantics are unchanged; LIMIT retains zero/negative behavior.
- Added four SQLite tests covering limit boundaries, source isolation, reorder rollback/retry, search rules/bound parameters/quoted folders and global candidate cutoff. After completing a required cover field in the fixture, all 796 Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundary documentation; original user changes remain uncommitted. Read-triggered movement, tag editing/export, tracking data, connection lifecycle, other domains and remaining P5–P8/five-platform performance acceptance are still pending.

## P6: Read-triggered favorite movement and tracking persistence (2026-10-01)

- FavoritesRepository now owns read-triggered movement, tracking time comparison/writes, check times, acknowledgement, tracking lists/counts and identity queries. Tracking row decoding reuses favorite_row; tag replacement and export reads also moved. The manager and identity-cache isolate no longer execute SQL directly; settings, connections, caches and notifications remain manager-owned.
- Read-triggered changes commit atomically across participating folders, skip read-later and use one operation timestamp. Failures do not change tracking caches or notifications. The none preference still only acknowledges tracking; unknown/invalid movement preferences only update time. onRead retains void and removes async without await, allowing synchronous failure handling.
- Preserved same-version flag clearing, missing-identity errors, ID-only tag replacement across sources and original export fields/times without explicit ordering. Tracking comparison and writes share a retryable transaction.
- Added four repository tests and one manager test covering movement modes, cross-folder rollback/retry, source isolation, tracking fields/counts, missing identities, tags/export, cache/notification ordering and read-later exclusion. After correcting test interfaces and explicit ordering arguments, all 801 Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundary documentation; original user edits remain uncommitted. Initialization/close/clear lifecycle, hash collisions and asynchronous cache refresh, business coordination decomposition, other domains and remaining P5–P8/five-platform performance acceptance remain incomplete.

## P6: Complete favorite identities and snapshot merging (2026-10-01)

- Favorite references and tracking sets now use complete (id, type) keys, preventing XOR collisions from conflating counts, membership and update state. FavoriteIdentityIndex accepts snapshots by generation and overlays actual reference counts committed while a snapshot was in flight. Stale completions/failures cannot affect newer snapshots; failures preserve current state and allow retries.
- Add/move/copy/record/folder deletion reconcile affected identity references before notifying, removing blind reduceHashedId decrements. Bound queries batch by folder and at most 400 identities, avoiding per-identity queries and legacy SQLite parameter limits. Folder deletion/rename restart snapshots to avoid old table names. Initialization/close invalidate old index generations; close clears counts/tracking caches.
- Added three pure index tests, two manager tests and one repository test covering in-flight additions/deletions, generations/failure/clear-reopen, hash collisions, shared folder references, notifications after batch merge/deletion and query chunking. All 807 Windows Flutter tests passed; after adding snapshot restarts on folder structure changes, the final 67 favorite tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundary documentation; original user edits remain uncommitted. Shared initialization Futures/failure connection cleanup, whole-database clearing paths and all-isolate draining, business coordination decomposition, other domains and remaining P5–P8/five-platform performance acceptance remain incomplete. Existing refreshHashedIds/test-wait entry names remain available.

## P6: Favorite initialization and connection close (2026-10-01)

- Initialization registers its Future before execution. Concurrent/ready calls for the same path reuse it, while failure releases resources and allows a later explicit init retry. Changing data paths requires close. Appdata readiness precedes local-connection migration/default creation and publication, removing partial-initialization notifications through public createFolder.
- Close is repeatable, clears the connection/counts/identity/tracking indexes and invalidates old initialization generations. Closing after the initializer body finishes but before its Future is delivered also reports failure; late failure cannot dispose a reopened connection. clearAll closes and rebuilds using the original connection path, avoiding deletion at a changed global path, but does not yet drain all in-flight isolates.
- openSqliteDatabase now disposes an unreturned connection when PRAGMA setup fails. Added four manager tests and one factory test covering shared results, migration failure release/retry, repeat close, old initialization/reopen isolation, rejected path switching and corrupt-database release.
- All 812 Windows Flutter tests passed. After adding the close check at initialization-result delivery, the final 75 favorite/SQLite tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed. Updated CHANGELOG and bilingual boundary docs; original user edits remain uncommitted.
- Read-task tracking/draining, clear/import coordination, failed-clear recovery, coordination decomposition and remaining P5–P8/five-platform performance acceptance remain pending. Connection initialization does not complete the entire favorite lifecycle.

## P6: Favorite read draining and import close barrier (2026-10-01)

- The manager tracks folder/all-comic/identity-snapshot reads with captured paths and connection generations. Closed managers reject new reads; successful results from old connections become invalidation errors. Completed/failed tasks leave the registry. closeAndWait drains every accepted read, including superseded snapshots, before returning; synchronous close remains for state invalidation.
- init waits during draining; same-path init and concurrent clearAll calls share the clear result. Clearing drains before deleting the owned path. Both import replacement and rollback await favorite closeAndWait; close errors are no longer swallowed before replacement.
- Added three manager tests and two real archive import tests covering concurrent reads/stale results, file renaming after release, no database recreation after close, draining/reopening, shared clear/path isolation and successful import or corrupt-database rollback followed by reopening. The 74 favorite tests and two import tests passed, as did all 817 Windows Flutter tests. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundary documentation; original user edits remain uncommitted. Independent export isolates, failed-clear recovery, whole-operation import/storage-migration coordination, business coordination decomposition and remaining P5–P8/five-platform performance acceptance remain pending.

## P6: Failed favorite-clear recovery and shared file replacement (2026-10-01)

- Clearing drains readers and moves the old database to a same-directory temporary backup, discarding it only after the new database initializes successfully. Initialization failure restores the original file and tracking/quick-favorite settings and reopens. Failed recovery logs original/backup locations and retains backups; cleanup errors after success are logged without undoing the clear.
- Extracted FileReplacement, shared by clearing and application-data file import. Restoration verifies backup presence before deleting the current file, and rejects backup-name collisions or unprepared state. Directory import retains its existing implementation.
- Added four replacement tests and one manager failure-injection test covering original restore/commit, originally missing files, missing backups, failed restore renames retaining backups and blocked settings writes restoring favorites/tracking/settings before successful retry. All 81 targeted favorite/import/replacement tests and all 822 Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundary documentation; original user edits remain uncommitted. This verifies runtime exception recovery, not automatic power-loss/crash recovery. Independent export reads, whole-operation cross-domain coordination, business coordination decomposition and remaining P5–P8/five-platform performance acceptance remain pending.

## P6: Serialized app-data bulk operations and isolated archives (2026-10-01)

- Added AppDataOperations to run normal/Pica import, export and favorite clearing in submission order across archive workers, replacement/rollback/cleanup. Failures release subsequent requests. Clearing separates queued requests from active execution to avoid an import waiting on a clear queued behind it.
- Export uses UUID paths, closes compression handles on error and removes partial output. Settings-page import also uses unique staging files with copy-failure cleanup. Queue order/failure tests and a real import→export→clear→export integration test verify independent paths/content, failed-export cleanup/retry and no circular wait.
- Combined tests repeatedly terminated without a stack. Dependency inspection confirmed zip_flutter 0.0.13 registers an extraction callback argument with a finalizer and also manually frees it. Normal/Pica extraction now uses the existing archive streaming decoder with explicit input/output closing and propagated write failures, rejecting links/out-of-directory entries. Test ZIP inspection also avoids that native extractor. The same combination and full suite then passed; no dependency upgrade or vendored edit was made.
- Added two queue tests and one integration test. All 825 Windows Flutter tests passed; after settings staging isolation and lint cleanup, the final 100 favorite/settings/import/queue tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed. Updated CHANGELOG/bilingual boundaries; original user edits remain uncommitted.
- This bulk queue does not freeze normal SQL writes or lock other processes. Consistent database export snapshots, service decomposition and remaining P5–P8/five-platform performance acceptance remain incomplete. Local-comic import/migration retain their own storage guard for a different file set.

## P6: SQLite snapshots for application-data export (2026-10-01)

- Export awaits accepted history writes, saves settings and freezes current JSON. Sync exports apply the existing exclusion rules, fixing stale syncdata.json reuse after exclusions are cleared. The user-edited appdata implementation was not changed.
- Added createSqliteSnapshot using read-only sources, pinned read transactions and SQLite backup. Standalone copies retain committed WAL contents, schema/rowids/BLOBs without changing source journal mode, creating missing sources or overwriting existing targets. app_data_snapshot stages the three databases plus settings/source files before compression; success/failure clean staging.
- Added three SQLite snapshot tests and one export integration test covering committed WAL versus later writes, standalone integrity_check, rowid/index/blob preservation, corrupt/missing sources and destination protection, pending history writes, changed exclusion rules, source contents and failed-export staging/partial-output cleanup. Seven targeted tests and all 829 Windows Flutter tests passed. After a braces lint fix, final analysis has no errors/warnings and 23 existing infos; structure, architecture and Git dependency checks passed.
- Updated CHANGELOG and bilingual boundaries; original user edits remain uncommitted. Each database is internally consistent, while databases/settings are sampled sequentially; this does not claim a cross-database transaction, cross-process freeze or device performance acceptance. Service decomposition and remaining P5–P8/five-platform acceptance continue.

## P6: Archive filesystem work separated from business orchestration (2026-10-01)

- Added AppDataArchive with explicit paths/frozen settings, owning snapshot staging, background compression/extraction and temporary cleanup without App/appdata or business managers. app_data_transfer removes direct ZIP/isolate handling while retaining bulk queueing, version/settings decisions and import rollback; normal/Pica imports share the service.
- Archive creation rejects existing destinations. Extraction validates every entry before writing so later invalid paths cannot leave earlier files. Callers still own extraction-directory failure cleanup and receive write errors.
- Added three service tests covering a round trip without application globals, destination protection and complete preflight. Seven targeted import/snapshot/archive tests and all 832 Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure, architecture, Git dependency checks and 12 architecture-script tests passed.
- Archive/snapshot services are enrolled in business dependency checks. Updated CHANGELOG and bilingual boundaries; original user edits remain uncommitted. Legacy Pica parsing, import coordination/favorite service decomposition, other domains and remaining P5–P8/five-platform performance acceptance continue.

## P6: Legacy Pica decoding and import coordination (2026-10-01)

- LegacyPicaReader decodes favorites, folder links, history and image favorites through a caller-owned SQLite connection without writes or global managers. A separate coordinator opens source databases read-only; the public entry retains the bulk-operation queue. The decoder is covered by the business dependency gate.
- Fixed integer chapters failing conversion into the string read-episode set and image IDs being truncated at additional hyphens. Preserved distinct nhentai numbering, empty tags, quoted folder names, source aliases, existing-link precedence and unavailable-source skipping.
- Added four decoder tests and one real-archive import test including repeated import and invalid link JSON. Eight targeted and 837 full Windows Flutter tests passed. Final analysis has no errors/warnings and 23 existing infos; structure/architecture gates, 12 architecture-script tests and Git dependency checks passed.
- Updated changelog and bilingual boundary/progress docs without staging original user changes. Existing per-section error handling can still produce partial imports; preflight/transactions, remaining service decomposition and P0–P8 acceptance remain incomplete.

## P6: Legacy import decoding preflight (2026-10-01)

- Added LegacyPicaData without global manager dependencies. It fully decodes pending favorites, history and available-source image records, releasing read-only source connections before destination writes. Late decoding errors reach existing UI error handling instead of silently leaving earlier rows imported. Empty sections skip writes.
- Preserved existing-link precedence, per-link invalid JSON logging/skipping and unavailable-source image skipping. Absent source databases remain optional; present databases with invalid schema/row types no longer partially import.
- Added a real-archive regression injecting late favorite tag, history chapter and image identity errors, verifying original favorites, no new folder/history, no import notifications, cleanup and successful repair/retry. Drained initialization cache notifications before observing import. Six targeted and 838 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed.
- Updated changelog and bilingual docs, preserving original user changes. Preflight holds decoded models in memory; large-data performance is unverified. Cross-domain write transactions, cache/notification commit boundaries and other P0–P8 work remain incomplete. No writes on decoding failure does not imply atomic whole-archive import.

## P6: Image favorite repository and batch deletion transaction (2026-10-01)

- ImageFavoritesRepository owns schema, queries/search, count, writes and deletion. image_favorites_row decodes rows; models no longer depend on SQLite or row JSON construction. Preserved compact legacy JSON, default chapter maxPage=1, empty tags, source identity, first-duplicate precedence, positive chapter/page filtering and automatic favorite flags. Repository/mapper are covered by the business dependency gate.
- Batch deletion captures input, builds pending records and commits every update/deletion through saveAll before async cache cleanup and notification. Failure preserves cache files and emits no success notification; cleanup failures are logged separately. Manager queries retain decode-error logging/empty results and SQLite-error propagation.
- Cache deletion now uses the provider's full cache key, fixing the mismatch with write keys and preserving source isolation. Added three repository and two manager/cache tests for old row defaults, queries, normalization, rollback/retry, cache preservation on failure and notification timing.
- Fixed uninitialized global paths in the new test setup. Seven targeted and 843 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture gates, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog and bilingual docs while preserving original user changes.
- This transaction covers image favorite batch deletion; legacy import favorites/history/images still need a combined cross-database commit, cache/notification commit boundaries and remaining P0–P8 work.

## P6: Composable repository transactions and savepoints (2026-10-01)

- Added synchronous runSqliteTransaction. Standalone calls retain deferred/immediate modes; calls inside an existing transaction use unique savepoints. Success releases only the owned scope, failure rolls it back, and the outer caller owns final commit. Callbacks must not commit/close the connection or start async work.
- Favorites, history progress/duration/conditional and batch deletion, and image favorite batch writes share the helper, removing duplicate BEGIN/COMMIT/ROLLBACK code. SQLite automatic rollback no longer causes an invalid rollback to mask the original error; cleanup failure retains both operation and rollback errors/stacks.
- Added five real SQLite tests for inner success without outer commit, recoverable inner failure, commit-time constraint failure/automatic rollback, two-connection lock modes, and combined repositories rolling back favorites/history when an image write fails, with successful retry. Outer rollback also covers repository deletion operations.
- Forty-eight targeted and 848 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog and bilingual docs, preserving original user changes.
- These tests establish same-connection composition, not atomic legacy import across two database files. Attached-schema addressing, business commit entry, cache/notification updates and remaining P0–P8 work are still pending.

## P6: Attached database repository addressing (2026-10-01)

- HistoryRepository and ImageFavoritesRepository accept an explicit schema, defaulting to main. All reads, writes, deletes, table creation and history column migrations target that schema. Aliases are double-quote escaped and missing schemas fail rather than implicitly resolving same-named main/attached tables. Stored fields and default main-database calls remain unchanged.
- Added three file-backed regressions for quoted Chinese aliases, main-table isolation, old-column migration, every history read/statistics/delete path, image lookup/search/deletion and invalid/injection-like aliases. Main favorites and attached history/images share one transaction: image failure rolls back the new favorite table and history; retry is verified through independent read-only connections to both files.
- Twenty-two targeted and 851 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog and bilingual docs, preserving original user changes.
- This unit enables cross-file storage composition and verifies ordinary runtime rollback. The legacy import coordinator does not yet call it; post-commit manager cache/notification handling, cross-file crash recovery verification and remaining P0–P8 work are still incomplete.

## P6: History cache invalidation after external commits (2026-10-01)

- HistoryManager.notifyChanges refreshes identities and clears recent record values before notifying, preventing stale titles/pages after external replacement of the same identity. Ordinary updateCache/incremental record keep unchanged cached values. HistoryCache builds the complete identity snapshot before publishing; failed reads preserve existing identities and records.
- Added cache failure injection and manager external-repository-write regressions for failed-read preservation, retry with fresh fields, listener visibility and later progress writes retaining updated metadata. Thirty-one targeted and 853 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed.
- Updated changelog and bilingual docs while preserving original user changes. This repairs the existing notification entry; legacy import cross-database transaction wiring and favorite cache commit coordination remain pending, along with other P0–P8 tasks.

## P6: Pica cross-database import wiring (2026-10-01)

- pica_import_storage uses one outer transaction over main favorites and attached history, composing all three repositories. SQL failures in links, folders, favorites, history or images roll back and propagate to the UI. Only invalid optional link JSON remains skippable; existing links win. Targets must exist and use rollback journals; this connection uses FULL synchronous mode. WAL targets are rejected before writes without changing their mode.
- HistoryManager.importStorage queues the synchronous commit with existing history writes and checks connection generation. Earlier accepted writes finish first, later writes follow; failure does not poison the queue and closed-generation imports cannot write. After commit, favorite counts/full identities/tracking and history caches reconcile before domain notifications.
- Images load/merge/save only affected identities, preserving existing metadata, image keys/auto flags and first duplicate pages without rewriting unrelated corrupt rows. Image models are exported through history_api; storage is covered by the business dependency gate.
- Added four storage regressions and one queue regression, extending the real archive test for failed-history rollback/no notifications and cross-domain visibility at successful notification. Covers final-image failure, repeated import, merge, optional-link versus SQL errors, WAL rejection/retry. Full Windows Flutter 857 tests passed; after adding WAL coverage and cleaning new analysis infos, final targeted 26 tests passed. Final analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 architecture-script tests and Git dependencies passed.
- Updated changelog/bilingual docs, preserving user changes. The synchronous transaction may block the main isolate; large-import performance is unverified. Post-commit cache/notification failure cannot undo committed data. Crash/power-loss recovery, cross-process coordination and remaining P0–P8 work are not complete.

## P6: Import directory rollback protection (2026-10-01)

- Added DirectoryReplacement to application-data import, replacing target deletion before backup validation. Restore verifies the original backup is a directory and refuses conflicting target types. Backup rejects occupied backup paths and non-directory targets; construction rejects normalized equal/ancestor paths. Failures retain state for recovery retry.
- Removed duplicate wasExisting state from the importer; file and directory replacement objects each track successful preparation. The overall import coordinator still owns backup cleanup after successful import.
- Added five directory regressions for full-tree recovery, missing/wrong-type backup preserving current data, target conflicts preserving backup/retry, reverting a newly created tree and overlap/occupied-backup rejection. Twelve targeted directory/file/import and 863 full Windows Flutter tests passed. After correcting two brace infos, final analysis has no errors/warnings and 23 existing infos; structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed.
- Updated changelog and bilingual docs, preserving original user changes. Verified ordinary runtime recovery, not crash/power-loss recovery or concurrent external filesystem mutation. Remaining P0–P8 work continues.

## P6: Read-later coordination separation (2026-10-01)

- ReadLaterService owns configured-folder validity, full-source identity lookup, limited reads, collision naming, inclusion/removal and settings-save coordination without application globals or pages. Repository/settings callbacks resolve current state on each call, avoiding retained closed connections. Creation/front insertion/deletion still use manager callbacks for cache/notification behavior. Collision selection reads folder names once and preserves suffixes starting at (2).
- Manager public APIs remain unchanged for pages. The service is covered by the business dependency gate. Added a SQLite service test without global resets for repository replacement, stale/non-string configuration, removal of absent items, folder recreation and old-database preservation.
- Fixed nullable local promotion found during initial compilation by using a non-null folder candidate. Thirty-three targeted and 864 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog and bilingual docs, preserving user changes.
- This separates read-later policy ownership while retaining existing folder/create/add/settings-save order; it does not introduce a database/config-file transaction. Tracking coordination, other P6 domains and remaining P0–P8 acceptance continue.

## P6: Tracking identity state service and folder switching (2026-10-01)

- FavoriteUpdatesService owns tracking folder/full identities, refresh/clear and committed update/read changes. Repository and configuration resolve through injected callbacks without app globals or UI notifications. The manager retains storage writes and notification ordering; the service is covered by the business dependency gate.
- Fixed single-record updates after a configured-folder switch relabeling old-folder identities as the new folder. A different folder triggers a complete current-folder refresh, avoiding leaked old flags and missing existing new flags. Folder and identities publish together only after successful loading; failure retains the prior snapshot and close clears state. Added manager switching coverage and a service test without global resets for failed refresh, clear and source isolation.
- Thirty-four targeted tests passed. The initial full suite failed a Pica staging-cleanup assertion: both normal/Pica finally blocks failed to await async deletion. An isolated rerun passed but did not remove the race. Awaiting staging/backup cleanup before releasing the bulk queue was committed separately as ecaafab. The corrected full Windows Flutter suite passed 866 tests; final analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 architecture-script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual docs and preserved user changes. This separates tracking identity state; request scheduling, other domains, performance and remaining P0–P8 acceptance continue. Cache loading happens after storage commit and failure cannot undo that commit.

## P6: Atomic single-folder favorite JSON import (2026-10-01)

- importFavoriteFolder owns root/name/list validation, complete model decoding, tag translation, collision selection and repository transaction. All records decode before folder creation; any SQL failure rolls back the new folder and earlier records instead of swallowing per-row errors. The manager reconciles counts/identities/tracking and notifies once after success; existing UI error handling receives failures.
- Preserved FavoriteItem.fromJson legacy source mapping, collision suffixes from (0), full-identity deduplication, front/end insertion settings and empty-folder import. The service is covered by the business dependency gate. Added three service and one manager regression for late bad records, translation failure, trigger-injected insert rollback/retry, collision/order/duplicates and cache visibility at notification.
- Twenty-nine targeted and 870 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog/bilingual docs, preserving original user changes.
- This entry uses a synchronous database transaction; large-import performance and crash recovery are not accepted. Post-commit cache failure cannot undo the committed folder. Other P6 domains and remaining P0–P8 work continue.

## P6: Local comic model and row mapping separation (2026-10-01)

- Moved LocalComic into local_comic_model using comic-source data APIs and the shared history contract, without LocalManager, SQLite or filesystem paths. coverFile/baseDir now live in LocalComicFiles in local.dart, available through existing local/local_comics exports; relative/absolute path rules remain unchanged.
- local_comic_row decodes actual column names instead of SELECT positions. Five manager query paths share it, preserving downloadedChapters, chapter JSON, timestamps and malformed JSON errors. Model/mapper are covered by the business dependency gate; manager SQL still needs repository extraction.
- Added real SQLite reordered-column and malformed-JSON coverage. Nine targeted local model/manager/reading/natural-sort and 871 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 architecture-script tests and Git dependencies passed. Updated changelog/bilingual docs, preserving user changes.
- Local queries/migrations, directory access, download queues and recovery remain to be separated. This does not complete P6 or remaining P0–P8 work.

## P6: Local query repository (2026-10-01)

- LocalRepository owns list queries, full-source identity lookup, recent 20 items, count, exact title/directory lookup and search, sharing local_comic_row. The manager retains its public entrypoints and connection ownership. LocalSortType moves to a separate file re-exported by the existing entrypoint, avoiding a repository dependency on the manager.
- Preserved descending title order, ascending/descending timestamps, LIKE wildcards/tag/subtitle matching with descending time, and first-result exact name lookup. The repository is covered by the business dependency gate. Added real SQLite coverage for identities, ordering/limits, bound parameters and unknown-sort fallback.
- Nine targeted and 872 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture checks, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog/bilingual docs, preserving user changes.
- Local writes, schema/natural-sort migration, directory management and download recovery remain in the manager pending further separation; remaining P0–P8 acceptance is incomplete.

## P6: Local basic writes and migration-marker transactions (2026-10-02)

- LocalRepository owns comics/natural_sort_migration initialization, numeric ID lookup per source, insert/replace and deletion. New markers and comic writes commit together; deletion of markers and comics is also transactional. The manager emits its existing notification only after success. Writes name columns explicitly and preserve schemas and existing migration progress.
- Downloaded chapters merge into a new list, supporting const/immutable input without mutating caller models. New-before-old ordering and duplicate semantics remain. Added real SQLite failure injection for no orphan markers on insert failure, marker restoration on delete failure, retry, overridden IDs, source isolation and immutable inputs.
- Ninety-two local-module and 873 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 architecture-script tests, Git dependencies and unit formatting passed. Updated changelog/bilingual docs, preserving user changes.
- Natural-sort migration workflow, remaining chapter deletion/recovery SQL, connection lifecycle, directory/download responsibilities and remaining P0–P8 acceptance continue.

## P6: Natural-sort migration persistence and retry (2026-10-02)

- LocalRepository owns mapping reads/first writes using LocalPageMigration, including nullable new-import markers. Explicit columns and transactional conflict handling preserve the first complete-identity record after concurrent image enumeration.
- The manager retains image sorting/history coordination, captures old page/time before enumeration, and persists mappings before history. Failed history writes restore a still-matching in-memory conversion for same-object retry. Tests cover concurrent callers, real history UPDATE failure/retry, repository write failure, source isolation and new-import markers. The initial injection incorrectly targeted INSERT; switching to the actual UPDATE path verified failure handling.
- All 95 local-module and 876 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and unit formatting passed. Updated changelog and bilingual structure/progress docs; user edits preserved.
- This unit does not add local/history cross-database atomicity or complete connection switching, chapter deletion/recovery, directory/download responsibilities or remaining P0–P8 acceptance.

## P6: Local chapter and batch deletion repositories (2026-10-02)

- LocalRepository owns chapter/batch deletion; LocalManager executes no SQL. Single, last-chapter and batch removals share comic/marker cleanup. A later batch failure rolls back earlier records and all markers; nested scopes do not commit their parent transaction.
- Chapter deletion reads current stored downloads in the transaction, preventing stale page models from discarding later downloads. Unselected ordering/duplicates, source identity and immutable input behavior are preserved. The manager retains file/favorite/history coordination; database failure prevents subsequent file deletion and success notification. Batch failures retain log-and-return semantics.
- Added four repository and two manager regressions covering UPDATE/DELETE trigger failures, retries, duplicate/missing identities, empty selection, nested rollback, file retention and notification visibility. All 101 local-module and 882 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog and bilingual architecture/progress docs, preserving user edits. SQL ownership is complete, but connection lifecycle, reliable file deletion, download tasks/recovery, directory migration, cross-database consistency and remaining P0–P8 acceptance remain open.

## P6: Download snapshots and complete restoration (2026-10-02)

- DownloadTaskStore owns JSON serialization, ordered writes and full decoding with supplied paths/codecs/error reporting, enrolled in business dependency checks. Nested state and destination are captured when saving. Writes stage/flush beneath the target parent, rename into place and await cleanup; failure leaves later writes usable.
- The manager publishes a replacement queue only after complete decoding, fixing partial restoration followed by snapshot deletion on later invalid entries. Failure retains the current queue/file, repeated restoration avoids duplicate append, and unsupported task kinds remain skipped. Existing save/drain APIs remain.
- Four store and one manager regressions cover frozen snapshots/destinations, replacement failure and retry, serialization failure preserving previous data, malformed JSON/tasks and repeated restoration. Initial Windows path-string assertions failed on separator differences; filesystem identity comparisons resolved them. All 106 local-module and 887 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. This unit verifies ordinary filesystem failures, not power-loss/crash atomicity across platforms. Active task lifecycle, completion commit ordering, directory migration, cross-database consistency and remaining P0–P8 work continue.

## P6: Retain tasks when download completion cannot commit (2026-10-02)

- Fixed completeTask continuing after unawaited async add(). Repository commit now finishes synchronously before queue removal, one notification, queued snapshot and next-task resume. Failure retains the current task/old snapshot, leaves the next task stopped and rolls back comic/migration rows.
- Image/archive completion catches commit errors into paused error state; image speed recording stops. Success clears the running flag. Two real SQLite regressions cover unchanged queue/snapshot and no notification on failure, committed state visible on successful retry notification, and image task retry with recorder shutdown.
- All 108 local-module and 889 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits.
- This is a separate behavior fix. Snapshot failure after database commit, active download lifecycle and directory consistency remain open. Archive completion catch paths compile/pass full regression, but no new real-network ZIP end-to-end fault injection was added. Remaining P0–P8 acceptance continues.

## P4/P6: Image download run ownership and error handling (2026-10-02)

- Each image resume gets a generation invalidated by pause/cancel/error shutdown. Metadata/image-list/snapshot continuations, retries and prefetch callbacks validate ownership. Obsolete request errors cannot stop a newer run, and late snapshot errors cannot relabel an explicitly paused task.
- Resume handles otherwise escaping file/snapshot errors while preserving retryable tasks. Error/pause share prefetch cancellation, retry wakeup and recorder cleanup, removing duplicate completion error handling. Chapter image lists publish only after complete fetching, avoiding partial lists being treated as ready after resume; removed an ineffective cache branch after empty-map creation and maintained chapter fetch counts.
- Three regressions cover real replacement failure/late paused failure/retry, obsolete metadata errors leaving a newer run intact, and paused chapter fetching never publishing partial state. Final 111 local-module and 892 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits.
- Download lifecycle work remains: archive generations, draining canceled underlying I/O, snapshot failure recovery after database commit, queue-service separation and remaining P0–P8 acceptance are not complete.

## P4/P6: Draining image cancellation and chapter cleanup (2026-10-02)

- Image wrapper cancel returns a stable future; canceled waiters drain stream closure and already-started writes rather than returning on the flag alone. Waiter publication also waits for cancellation completion. Pause/error aggregate stop futures, resume waits, and pendingCleanup exposes completion.
- Cancel captures paths/unregistered chapter selection, stops prefetch and removes the task before awaiting stops and directory cleanup. Registered chapters of existing comics remain; deletion uses getChapterDirectoryName. Additional-chapter cancellation no longer synchronously deletes directories with active transfers.
- Two controlled stream-cancellation-delay regressions verify no new stream/early directory deletion before release, subsequent resume/cleanup, and registered-file retention. All 113 local-module and 894 full Windows Flutter tests passed. After fixing one new null-aware collection syntax info, final download-file tests passed and final analysis has no errors/warnings with 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. Tests control stream-close delay, without separate filesystem-write-delay injection. Thumbnail requests, archive runs, cross-instance directory exclusion, post-commit snapshot recovery and remaining P0–P8 acceptance continue.

## P6/P8: Chapter directory rules and shared-directory protection (2026-10-02)

- local_chapter_storage extracts pure mapping/deletion selection under business boundary checks. Reading/downloading call the pure mapper, cancellation/chapter deletion share cleanup selection. Removed the old LocalManager static method after checking/migrating repository callers; existing directory names remain unchanged.
- Cleanup protects mapped directories still referenced by registered chapters, preventing a/b and a:b aliases sharing a_b from deleting retained content. It conservatively folds case/trailing dots/spaces, excludes empty/dot targets and deduplicates. Case-sensitive filesystems may retain extra ambiguous directories; this is not complete directory garbage collection.
- Added three policy tests and expanded real cancellation coverage for original mapping, retained aliases, deduplication, immutable input, dot paths and shared-file retention. The expanded fixture initially exposed a stale expected registered-chapter list; updating that expectation yielded 116 passing local-module tests. After migrating the final mapping caller, all 897 full Windows Flutter tests passed.
- Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits. Cross-instance directory ownership, image/thumbnail/archive lifecycle, snapshot consistency and remaining P0–P8 work continue.

## P2/P6: Download contracts, implementations and decoding (2026-10-02)

- DownloadTask moved to download_task, depending only on foundation ChangeNotifier, comic type and local model under the business gate. The download list imports this contract directly. download_task_codec owns existing image-task dispatch; the base static factory was removed and the manager uses the decoder function.
- Image/archive implementations moved to images_download_task/archive_download_task. Removed 13 unused imports after separation; the image implementation no longer directly imports ZIP/SAF/file-downloader code. download.dart remains an actively used export entry. Persisted supported kinds and fields are unchanged.
- Direct comparison with pre-change source confirms both implementation bodies and image-private helpers are identical. Existing 116 local-module and 897 full Windows Flutter tests passed. Final analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. This responsibility migration adds no tests that duplicate implementation. Concrete tasks still depend on manager/source runtime; queue services, injection, lifecycle/persistence consistency and remaining P0–P8 work continue.

## P6: Download queue service and instance ownership (2026-10-02)

- DownloadQueue owns ordering, identity lookup, add/remove/front moves and completion advancement through synchronous commit/notification/save-request adapters. It has no globals/files/concrete tasks and is business-gated. LocalManager delegates existing methods, removing duplicate orchestration; successful commit precedes removal/notification, with save requests queued in the existing order.
- Add deduplicates id/type; completion/removal/reordering require exact queued instances so late callbacks cannot mutate same-comic replacements. Empty/missing/already-front moves are no-ops rather than first-element errors or insertion of strangers. Running/paused front-move behavior and removal without automatic advancement remain.
- Three service tests without global resets cover notification/save/start ordering, source isolation, duplicate add, both reorder states, stale callbacks and failed-commit retry; existing manager integrations still pass. All 119 local-module and 900 full Windows Flutter tests passed, with no analysis errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. Restoration/tests retain a mutable list view; snapshot failure recovery, listener reentrancy, lifecycle, task dependency injection and remaining P0–P8 acceptance continue. The whole download domain is not complete.

## P6: Download queue listener reentrancy (2026-10-02)

- DownloadQueue revalidates revision/head/target after pause callbacks, avoiding stale-index moves when listeners remove targets. Completion resolves the exact instance again after model conversion/synchronous commit, avoiding wrong deletion or range errors when earlier tasks disappear.
- An identity set prevents recursive completion of the same task and is released in finally for retry. Nested service mutations during notification/save suppress outer duplicate starts; the latest operation owns scheduling. Existing notify-before-save ordering remains.
- Four regressions cover pause-listener target removal, nested notification adds starting once, commit callbacks shifting indices and recursive same-task completion committing once. All 123 local-module and 904 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. Revisions cover service mutations, not direct edits through the still-mutable view. Queue lifecycle, snapshot recovery, concrete task dependencies and remaining P0–P8 acceptance continue.

## P6/P8: Read-only queue views and paused snapshot restoration (2026-10-02)

- Queue storage is private; its UnmodifiableListView reflects service updates while removing mutable compatibility access. restorePausedTasks fully enumerates/validates paused inputs, keeps the first id/type, verifies the current queue is not active/completing or changed during collection, then publishes once and advances revision.
- LocalManager.restorePausedDownloads installs decoded snapshots and is used by disk restoration. Tests migrated from direct add/addAll/clear calls. Restoration emits no notification/save/start and is not cancellation/disposal; callers still own draining cleanup after pause.
- Three regressions verify immutable live views, complete silent restoration/deduplication/lazy-input failure retention, and active current/incoming task rejection. All 126 local-module and 907 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. Mutable queue access is closed; instance disposal, cleanup draining, snapshot failure recovery, task dependency injection and remaining P0–P8 acceptance continue.

## P4/P6: Archive run ownership and cleanup draining (2026-10-02)

- ArchiveDownloadTask accepts downloader/extraction adapters, defaulting to existing FileDownloader and ZIP/SAF behavior. Generations isolate status, extraction, cleanup and completion. Resume drains the prior run and queued stops/directory cleanup; the async entry catches directory/transport/completion failures for retry.
- Cancel captures the original path, invalidates the run/removes its queue entry immediately, then drains the run/stop (including noninterruptible extraction) before directory cleanup. Pause stops transport and zeros speed; stale errors cannot alter a newer run. pendingRun/pendingCleanup expose completion for tests and lifecycle adapters.
- Three adapter regressions cover obsolete extraction errors with serialized resume, cancellation waiting for extraction writes before deletion, and repeatable transport failure without async-void escape. All 129 local-module and 910 full Windows Flutter tests passed. After one braces-info fix, final download tests passed; final analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. New tests use controlled transport/extraction adapters, not real-network ZIP/SAF all-platform acceptance. Shared temporary paths, existing-comic cancellation policy, cross-instance isolation, snapshot consistency and remaining P0–P8 work continue.

## P6: Isolated archive task workspaces (2026-10-02)

- Each ArchiveDownloadTask owns a cache workspace for ZIP/resume sidecars instead of shared App.dataPath/archive_downloading.zip. Pause/retry reuse the instance workspace; successful commit or drained cancellation cleans it. Cleanup errors retain/log the path without undoing successful commit state.
- SAF extraction uses an independent child under the ZIP parent with finally cleanup, removing global archive_downloading cache use. Old temporary files lack ownership evidence and are not automatically removed/migrated. Persisted fields and supported archive restoration kinds remain unchanged.
- Added overlapping-task coverage for distinct temporary paths, first-task cleanup preserving the second ZIP/sidecar, and both tasks committing/cleaning independently. Extended pause/resume checks for path reuse/success cleanup and cancellation checks for workspace removal. All 130 local-module tests passed; after adding the cancellation workspace assertion, all 911 full Windows Flutter tests passed.
- Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits. Real Android SAF/platform testing, existing-output cancellation protection, process-exit cleanup, snapshot consistency and remaining P0–P8 work continue.

## P6: Archive output ownership protection (2026-10-02)

- Only newly allocated output is tracked as task-owned; existing library directories and externally supplied/restored paths are not claimed. Cancellation drains execution/extraction, rechecks registration through the original manager, and removes only unregistered owned output. Successful commit releases cleanup ownership.
- Added preservation regressions for registered/external output and late cancellation after successful commit; the extraction-drain test now uses normal output allocation. All 132 local-module and 913 full Windows Flutter tests passed. Analysis has no errors/warnings and 23 existing infos; structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog and bilingual structure/progress, preserving user changes. This does not provide rollback for extraction overwriting existing files; cross-instance allocation, thumbnail lifecycle, manager shutdown, snapshot consistency and remaining P0–P8 acceptance continue.

## P4/P6: Thumbnail cancellation draining and stale-write protection (2026-10-02)

- ImagesDownloadTask owns a StreamIterator for thumbnail consumption. Pause/cancel/error folds subscription cancellation into pendingCleanup, so resume and directory cleanup await it. Generation checks after consumption and before writing discard bytes from obsolete runs; finally closes the iterator and releases its reference by identity.
- An optional constructor loader defaults to ImageDownloader.loadThumbnail without changing snapshots. Two controlled-stream regressions cover delayed cancellation, cleanup/resume waiting and discarded old bytes. The initial fixture timed out closing an unlistened stream; the corrected fixture passed rerun.
- All 134 local-module and 915 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits.
- This validates task subscription ownership, not immediate termination of every platform HTTP connection. Image output ownership, manager shutdown draining, snapshot consistency and remaining P0–P8 acceptance continue.

## P6: Recheck registration before image cancellation cleanup (2026-10-02)

- Cancellation captures the original manager and a copied chapter selection, then reads comic registration/downloaded chapters after transfers stop. Cleanup uses that current record instead of the stale pre-cancellation snapshot, preserving existing directory mapping and alias protection.
- Two real-directory regressions cover initial comic registration and additional chapter registration while stream cancellation is pending. Both retain newly registered page files; existing unfinished-chapter deletion coverage still verifies actual cleanup.
- Unregistered image output ownership, cross-instance allocation/deletion exclusion and manager shutdown remain open. This recheck is not an atomic database/filesystem transaction; remaining P0–P8 acceptance continues.
- All 136 local-module and 917 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog and bilingual structure/progress, preserving user edits.

## P2/P6: Download directory allocation and concurrency boundary (2026-10-02)

- DownloadDirectoryAllocator injects library path/registered-directory lookup and serializes lookup, selection and creation. Existing unregistered empty directories, files and links are occupied, avoiding shared empty output for same-title tasks. Original 80-character title prefix, sanitization and numeric suffix conventions remain; allocation failure does not poison subsequent requests.
- DownloadDirectoryAllocation returns directory/newness. LocalManager delegates via allocateDownloadDirectory; both task callers migrated and the unused findValidDirectory entry was removed. Archive cleanup ownership now uses the allocation result instead of a pre-await registration snapshot. The global/UI-free service is enrolled in business boundary checks.
- Four service regressions cover concurrent same-title output, existing empty directories/files, registration while queued, source isolation, failure recovery and naming compatibility. All 140 local-module and 921 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user changes. Serialization covers one manager's download allocator, not other processes/importers/external filesystem mutations. Android SAF device and link creation were not newly validated. Image allocation cancellation ownership, writes to registered shared output, manager shutdown and remaining P0–P8 acceptance continue.

## P4/P6: Image output ownership and allocation draining (2026-10-02)

- Image tasks retain newly allocated directory ownership and original manager, folding the allocation Future into stop draining. Resume reuses late allocation results; cancellation waits for allocation/transfers and clears owned unregistered output even if path was initially null. Successful commit releases ownership. An optional allocation adapter defaults to the manager.
- Supplied/restored paths do not imply whole-directory deletion rights. Registered comics still use current chapter records, with a path-library equality check before chapter deletion to protect unrelated output carrying the same comic identity. Ownership is not added to snapshot fields.
- Four regressions cover cancellation during allocation, pause/resume allocation reuse, supplied/restored/unrelated registered-path preservation, and late cancellation after successful allocation/commit. Thumbnail cleanup tests now use real allocation. An initial Windows separator mismatch was fixed with path equality; all 144 local-module tests passed, then all 925 full Windows Flutter tests passed with extended external-path assertions.
- After fixing one formatter-induced braces info, final download tests passed (27); final analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user changes. Cross-process/import/delete exclusion, registered-output concurrent writes, manager shutdown and remaining P0–P8 acceptance continue; no new Android SAF device validation.

## P4/P6: Shared cleanup contract and move-to-front scheduling drain (2026-10-02)

- DownloadTask declares pendingCleanup, explicitly implemented by both concrete tasks and fixtures; the queue no longer needs concrete task knowledge. moveToFirst returns the stop completion Future, with LocalManager retaining the UI entry and supplying error reporting.
- The queue installs a stop barrier before pause callbacks. Reordering/notification/save remain immediate, but automatic starts await cleanup. Nested adds and overlapping moves share draining, revisions reject stale callbacks, and successive moves retain running intent. Snapshot restoration rejects a draining queue; synchronous pause errors and asynchronous cleanup failures report without starting the next task.
- Four regressions cover immediate reorder/deferred start and adds during draining, overlapping moves waiting for all stops, synchronous pause failure and asynchronous cleanup failure. Existing move/reentrancy tests now await the contract.
- This constrains automatic queue scheduling, not direct UI resume/pause, retired-task cleanup, manager disposal or complete window shutdown. Those lifecycle work items and remaining P0–P8 acceptance continue.
- All 148 local-module and 929 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits.

## P4/P6: Queue-owned manual controls and pending-start cancellation (2026-10-02)

- DownloadQueue.resume/pause accept only the exact current head. Manual resume uses the existing stop barrier and duplicate pending starts do not reschedule; pause advances the revision and clears start intent so late stop callbacks cannot restart a user-paused task. Notification reentrancy follows the latest revision.
- LocalManager adapts manual controls/pending state, replacing direct first.resume/pause calls in the download page. Pending starts keep a pause action available; stop failures clear pending intent and notify controls. Cancellation entry and task snapshots remain unchanged.
- Four service regressions cover manual resume waiting/duplicates/pause cancellation, stale/non-head references, notification-time pause preventing start, and failed-stop pending-state updates. All 152 local-module and 933 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user edits. Page wiring has analysis/full-suite compilation coverage, without new device interaction acceptance. Retired canceled-task cleanup, page subscription ownership, manager/runtime shutdown and remaining P0–P8 work continue.

## P4/P6: Queue cancellation and retired-task cleanup draining (2026-10-02)

- Download-page cancellation now uses LocalManager.cancelDownload/DownloadQueue.cancel. The queue installs its stop barrier before callbacks and reads pendingCleanup after cancellation returns, covering removal before directory cleanup registration. Subsequent adds/manual starts still wait for that cleanup. Pause/cancel share the same queue-local stopping mechanism.
- Cancellation checks object identity and guards recursive same-instance calls. Removal remains a no-op after concrete tasks remove themselves; other implementations are removed by the queue. Head cancellation does not auto-advance. Tail cancellation preserves pending-head start intent only when no newer listener pause/change supersedes it.
- Four service regressions cover cleanup assigned after removal, same-identity replacement waiting, stale/recursive cancellation and no auto-advance, tail cleanup chaining, and listener pause overriding old intent. The real ArchiveDownloadTask integration regression now cancels through the manager and adds a next task, proving it waits for extraction/output cleanup.
- All 156 local-module and 937 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits. Manager/runtime shutdown, page subscription ownership and remaining P0–P8 acceptance continue; direct out-of-queue task controls are outside this scheduling protocol.

## P4: Download-page subscription ownership and instance replacement (2026-10-02)

- The download page retains one LocalManager for subscription, reads, controls and disposal; tiles receive that manager. Head subscription starts in initState, removing duplicate registration from didChangeDependencies.
- Both head and reused tile updates use identical instead of DownloadTask id/type equality, so a new same-comic instance detaches the old listener and attaches the new one. Unmount removes page/tile listeners, retaining existing ValueKey identity and tile reuse.
- Three widget tests mount the page and verify stable listener counts across theme changes, same-identity replacement updates/old-listener removal, zero listeners after unmount, and pause-button cancellation of a start awaiting cleanup. This adds UI wiring evidence to prior service-control tests.
- Manager/runtime shutdown, other lifecycle work and remaining P0–P8 acceptance continue; this is not an application-wide no-leak claim or new device performance acceptance.
- All 3 page widget tests and 940 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user edits.

## P4/P6: Window-exit download quiescence and final snapshot draining (2026-10-02)

- DownloadQueue.suspend freezes admission/restoration/starts, pauses all current tasks and drains chained stops, including removed canceled tasks. Repeated calls share one Future. releaseSuspension matches that Future identity, rejects early release, and ignores stale releases; release never auto-resumes tasks.
- LocalManager.prepareDownloadsForExit handles only an existing manager, waits for suspension, saves the final task snapshot and drains writes. Failure releases that preparation and propagates; success returns an owned release callback. Database access remains available for synchronization.
- SyncWindowBinding uses the public local-library entrypoint to prepare downloads before existing history/upload waits. Failure, disposal or preparation completing after unmount releases the restriction. Existing forced-upload exit and reader-before-app sequencing remain; preparation is injectable for runtime tests.
- Six regressions cover retired cleanup/admission gating, all-task pause/failure retry/stale release, latest post-drain snapshot, snapshot-failure release, runtime download-before-history ordering and failure/disposal release. All 171 targeted local/runtime and 946 full Windows Flutter tests passed. After correcting the public import and one formatter info, 34 final targeted tests passed; final analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed.
- Updated changelog/bilingual structure/progress, preserving user changes. This covers normal WindowFrame exit, not OS termination/power-loss recovery or mobile background exit. Manager connection replacement/direct disposal, storage migration exclusion and remaining P0–P8 acceptance continue.

## P4/P6: Local-manager initialization and connection ownership (2026-10-02)

- LocalManager.init caches initialization, preventing concurrent/completed calls from replacing connections or restoring twice. Failure clears/closes the current connection, logs cleanup failures separately, preserves the original error/stack and permits retry. Explicit nullable connection state provides a state error before initialization/after disposal.
- dispose is idempotent and clears/closes the connection, including safe pre-init disposal. Post-await disposed checks prevent late source initialization from publishing restored tasks. A test factory injects connection/source initialization without replacing the singleton; production defaults remain unchanged.
- Exit preparation waits for an existing initialization Future before suspending/snapshotting downloads. With no initialization, immediate pause timing is retained; an initial unconditional await-null timing regression was fixed, then all 175 targeted local/runtime tests passed.
- Four real-SQLite lifecycle regressions cover concurrent/completed reuse with TEMP-table ownership, connection closure/original failure/retry, disposal during initialization preventing late publication, and pre-init repeated disposal opening no resources. Synchronous disposal of active downloads still does not replace full stopping; hot connection replacement, storage migration and remaining P0–P8 acceptance continue.
- All 950 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user changes.

## P2/P6: Directory migration service and path-commit consistency (2026-10-02)

- LocalStorageMigration owns validation, copy, path persistence, in-memory publication and old-directory cleanup through injected adapters, enrolled in the business boundary. Native directories resolve symbolic links before overlap checks; the SAF adapter uses provider paths because its plugin does not implement resolveSymbolicLinks.
- local_path is staged under its parent, flushed and renamed instead of truncating the previous configuration. Successful persistence publishes the in-memory destination before source cleanup. Cleanup/.nomedia errors are logged without relabeling committed migration; copy/configuration failure preserves the source and partial destination for inspection, without claiming automatic destination rollback or power-loss atomicity.
- LocalManager delegates/catches validation and IO errors for its existing UI result, retaining the PDF storage guard. Five real-directory tests cover commit order, copy failure, configuration failure, source-cleanup failure and overlap/canonical-alias/occupied-target validation. Existing PDF migration integration tests continue to pass.
- All 172 local-module and 955 full Windows Flutter tests passed; analysis has no errors/warnings and 23 existing infos. Structure/architecture, 12 script tests, Git dependencies and formatting passed. Updated changelog/bilingual structure/progress, preserving user changes. Active-download path migration, other import/delete exclusion, SAF device acceptance and remaining P0–P8 work continue.

## P4/P6: Coordinate storage operations with download ownership (2026-10-02)

- Migration and recovery use LocalManager.runWithExclusiveStorage. Active or paused queued tasks return busy until completed/canceled; absolute task paths are not silently rebased. An empty queue drains removed tasks' cancellation cleanup and rejects new downloads during the operation. Success/failure releases the restriction without restarting downloads.
- Normal window exit waits for an existing exclusive storage operation before acquiring its own queue suspension, preventing migration release from lifting exit restrictions. Existing PDF exclusion remains.
- Four integration regressions cover queued ownership, cancellation draining with real migration, failure release and exit ownership. Local/runtime targeted tests: 184 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests and Git dependency checks passed.
- Full Windows Flutter run: 958 passed, one failed because image-favorites cache deletion races with the existence-check/read sequence in readFromCache. This is recorded for a separate fix, not a passing full run. Changelog and bilingual docs are synchronized; user changes remain separate.
- Live task rebasing, other import/delete exclusion, draining PDF imports on exit, direct disposal, SAF device checks and remaining P0–P8 acceptance remain unfinished.

## P4/P6: Image-favorites cache read/eviction race (2026-10-02)

- Fixed the failure found by the preceding full run: ImageFavoritesProvider may lose a cache file between existence checking and asynchronous reading. On filesystem read failure it rechecks existence, treating a vanished file as a cache miss while preserving the original error for a remaining entry.
- Two deterministic regressions remove a real file between checking and reading and verify error propagation without removal. After initializing the fixture cache path, all 43 history tests passed; the race is not hidden by sleeps or reruns.
- Full Windows Flutter suite: 961 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed. The preceding full-suite failure is resolved; changelog updated with user changes kept separate.
- This change defines cache disappearance during reading, not serialization of all cache writes/deletions. Remaining P0–P8 lifecycle, business boundary, platform and performance acceptance work continues.

## P4/P6: Drain PDF imports during normal window exit (2026-10-02)

- PdfImportTasks.prepareForExit freezes batch admission/scheduling, cancels active/queued tasks and awaits results including conversion and FileSelection cleanup. Repeated preparation shares a Future; release matches that Future so stale releases cannot lift a later restriction. Release permits new batches without restarting canceled ones. Successful imports already in their commit phase retain success.
- SyncWindowBinding prepares PDF imports before download suspension, history writes and uploads. Preparation/later failures and unmount release acquired restrictions; successful exit holds them. Runtime uses the public local-library entry and an injectable adapter. Late picker results rejected during exit remain caller-owned and are disposed, with cleanup errors logged separately.
- Four regressions cover conversion/queued cancellation, delayed selection disposal, repeated/stale releases, commit completion, runtime ordering, download failure and unmount during preparation. Local/runtime tests: 188 passed; full Windows Flutter suite: 965 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Picker cleanup wiring is compilation-checked without new Android device testing. Direct task-manager disposal, other import/delete exclusion, OS termination/mobile background exit and remaining P0–P8 acceptance remain unfinished.

## P4/P6: Keep EPUB output and registration under one storage guard (2026-10-02)

- EpubComicImporter.import reuses LocalComicStorageGuard.runImport, waiting for migration/recovery before extraction and protecting output creation, optional registration and cache cleanup. Registration failure aborts this session's output; the registration adapter remains responsible for database rollback.
- The EPUB UI supplies registerComic to the importer instead of registering after it returns, removing the unprotected gap while retaining the success-count message. Busy wording now covers document imports (PDF and EPUB).
- Two real-archive integration tests cover waiting without extraction, blocking migration through registration, successful release and registration failure cleanup/retry. Local tests: 180 passed; full Windows Flutter suite: 967 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Archive shared-cache/cover-copy issues, directory/EhViewer exclusion, EPUB normal-exit draining, other deletion/lifecycle work and platform/performance acceptance remain unfinished; P6 is not complete.

## P4/P6: Archive temporary workspace and failed-output ownership (2026-10-02)

- CBZ.import allocates a unique temporary directory per invocation and extracts post-extraction work into a helper. Finally cleans the outer workspace, including single-directory archive wrappers, without deleting a shared cbz_import path. Both cover-copy branches are awaited before continuing or cleaning the cache.
- Existing output directories, files and links reject import, preserving unregistered/other-task data. Cleanup ownership starts after creating a fresh output; copy or page-range processing failure removes only that output. Page names, chapter keys and metadata behavior remain. This is not cross-process exclusive creation and does not include registration in the commit.
- Three real-archive regressions cover concurrent books/wrapped archives/chapter mapping/cover contents, post-cover range failure and retry, and preservation of existing empty directories/files. Local targeted tests: 183 passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Archive migration/recovery/registration coordination, directory/EhViewer exclusion, other exit lifecycle work and platform/performance acceptance remain unfinished.

- Final full Windows Flutter suite: 970 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.

## P4/P6: Coordinate archive registration and storage migration (2026-10-02)

- CBZ.import reuses LocalComicStorageGuard.runImport across workspace creation, extraction/copying, optional registration and cleanup. Registration failure reclaims newly created output; the registration adapter remains responsible for database rollback rather than implying a transaction across all persistence.
- Single/batch import pages register inside the callback. Batches commit/count per book and continue after individual errors instead of creating all output before registration. Single-book failure returns false rather than registering an empty collection as success; loading views close in finally.
- Default WebDAV restore passes registration to the real CBZ importer and awaits LocalManager.add before counting success; injectable import/registration adapters remain for tests. All three production CBZ.import call sites now supply registration callbacks.
- Three real-archive regressions cover waiting before extraction, protection through registration, registration failure cleanup/retry and the real WebDAV import chain. Initial local/backup tests: 195 passed; final targeted run including WebDAV integration: 16 passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Directory/EhViewer imports, general deletion exclusion, archive/EPUB exit draining and remaining P0–P8 architecture/platform/performance acceptance remain unfinished.

- Final full Windows Flutter suite: 973 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.

## P4/P6: Directory import protection and recovery registration boundary (2026-10-02)

- Directory/EhViewer entries acquire import protection after path selection, covering scanning, copying and registration without reserving storage while a picker is open. Public registerComics protects copying/registration for ordinary import flows; nested import counts still prevent migration.
- Recovery already owns exclusive storage and now calls private _registerComics, avoiding waiting on its own exclusive operation through the public entry. The internal method requires caller-owned import/recovery protection. EhViewer database closing moves to finally, including scan failures.
- Three real-directory/database widget tests cover waiting for exclusive work before direct/copy registration and completing actual recovery without self-deadlock. Full Windows Flutter suite: 976 passed; final local wiring verification: 189 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. System picker/EhViewer real database fixtures were not added. Directory output versus downloads/deletion, import exit draining and remaining architecture/platform/performance work continue; P6 is not complete.

## P4/P6: Freeze storage admission and drain accepted imports on exit (2026-10-02)

- LocalComicStorageGuard tracks completion at import admission, including imports waiting for migration. Exit preparation rejects new imports/exclusive operations and drains accepted imports plus migration/recovery. Completion signals do not swallow operation failures, which still reach their original callers. Preparation is shared and release identity prevents stale callbacks from lifting later restrictions.
- New local_import_lifecycle.dart composes PDF cancellation/cleanup with general storage draining. SyncWindowBinding uses this public entry before downloads, history and upload. PDF batches stop first so queued cancellation cannot start another item after storage freezes.
- Directory/EhViewer flows already holding import protection use internal registration instead of reacquiring admission during exit. Public UI admission maps busy rejection to a message/false. PDF documents rejected before conversion are disposed; entered conversions retain their existing cleanup ownership.
- Three new regressions cover accepted waiting imports, rejection/stale-release isolation, failed non-PDF draining/retry and PDF disposal on rejection. Directory widget regressions also assert exit rejection handling. Full Windows Flutter suite: 979 passed; final local/runtime targeted run: 202 passed. Final analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. This covers normal window exit and admitted guarded operations, not OS termination, mobile background exit, unguarded writers or arbitrary manager disposal. Download/delete ownership and remaining architecture/platform/performance acceptance continue.

## P4/P6: Awaitable deletion, storage exclusion and current paths (2026-10-02)

- Single/chapter/batch deletion returns a Future under runWithExclusiveStorage, rejecting active imports or queued downloads. Empty queues freeze admissions and drain cancellation cleanup until deletion finishes. Paths come from current registered records rather than stale page objects; missing identities are no-ops.
- File-deletion isolates return completion and history deletion is awaited. Batch SQL and filesystem failures propagate instead of silently reporting completion. UI confirmations await success, show errors and remove arbitrary chapter-deletion delay. Cross-database/filesystem rollback is not implemented; earlier side effects may commit before later cleanup fails.
- Queue suspend/releaseSuspension optionally suppress notifications; only confirmed-empty exclusive-storage calls use this to avoid two spurious library notifications. Normal download-exit notifications remain. Initial regressions exposed this difference and the original deletion notification contract now passes.
- A real SQLite/directory regression covers rejection of all three deletion kinds during import, current versus stale paths and completed file cleanup. Existing failure/notification tests await the new API. Local/runtime targeted tests: 203 passed; final manager tests after syntax/format fixes: 5 passed. Final analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests and Git dependencies passed.
- The first full run stalled at 155 tests for roughly 30 minutes, with its runner alive but no test workers. That runner was explicitly stopped before retrying; the stalled run is not counted as passing. User changes remain separate and changelog/bilingual docs are synchronized. Shared-directory/external-path ownership, deletion rollback, device checks and remaining P0–P8 acceptance continue.

- The full Windows Flutter retry passed all 980 tests in about 117 seconds; final changed-file formatting checks passed.

## P4/P6: Shared-directory deletion policy (2026-10-02)

- New pure localDirectoriesToDelete policy normalizes paths and preserves equal/ancestor/descendant overlaps with retained records. It rejects the library root and its ancestors, deduplicates normalized paths and returns original platform paths. Enrolled in the business dependency gate without manager/UI dependencies.
- Single/batch deletion queries retained records after removing target rows. Chapter deletion excludes only its owner and retains existing chapter-alias rules. All three filter paths before cleanup. Batch paths use the same baseDir resolution as single deletion, including external absolute paths.
- One policy matrix and three real-directory/SQLite regressions cover normalized aliases, shared roots until the last registration disappears, another comic rooted inside a deleted chapter, retained children protecting parents and library-root protection. Local targeted tests: 197 passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Comparisons are lexical and do not resolve symlink/SAF document identity, provide cross-process locks or database/filesystem rollback. These ownership/recovery issues and remaining P0–P8 acceptance continue.

- Full Windows Flutter suite: 984 passed. After fixing formatting-related brace hints, final policy/integration tests: 4 passed; final analysis: no errors/warnings, 23 existing infos. Structure, architecture, 12 script tests, Git dependencies and formatting passed.

## P6: Narrow directory-reference queries (2026-10-02)

- LocalRepository.directoryReferences selects only directory values and uses a bound full-identity exclusion for chapter owners. Deletion protection no longer reads, sorts and decodes every comic model; unrelated invalid tag/chapter JSON cannot block directory ownership checks. SQL stays in the repository and path resolution in the manager adapter.
- Existing baseDir and retained directory strings share one internal resolver, preserving current single-segment library paths and paths containing separators without divergent implementations.
- Two repository/real-directory regressions cover exact exclusion across source identities, binding, invalid display metadata and preservation of shared files. Local tests: 199 passed; full Windows Flutter suite: 986 passed. Analysis: no errors/warnings, 23 existing infos; structure, architecture, 12 script tests, Git dependencies and formatting passed.
- Changelog and bilingual structure/progress synchronized; user changes preserved. Eliminating unused columns/sorting/model decoding is not a measured device-performance result. Symlink identity, deletion rollback and remaining P0–P8 acceptance are unfinished.

## P3/P6: WebDAV configuration/storage boundary (2026-10-02)

- Extracted connection/path values into `webdav_library_config.dart`; introduced immutable `WebDavLibrarySettings` and injected reading, persistence and connection-invalidation callbacks. Startup, settings UI and scheduling share parsing; removed static fromSettings/saveToSettings methods.
- Preserved four legacy keys, three-string credentials, paths/authentication and cache keys. Reads do not repair storage; saves update only owned keys. Credentials now require exactly three strings. Invalid/non-finite/nonpositive intervals fall back to 360 minutes; positive custom intervals remain supported in the UI. Missing/malformed auto-sync follows the scheduler's true-only rule (the application default remains true).
- UI validates the connection before writing schedule options. Only a changed connection after successful persistence invalidates content; password changes invalidate, schedule-only changes do not. Persistence callbacks own rollback semantics; production appdata still updates memory before disk. This stage does not implement rollback or concurrent-save serialization.
- Added 7 tests for legacy round-trip/unknown keys, malformed values, password changes, persistence timing/failures and store isolation. WebDAV 32 tests and full Flutter 993 tests passed; analysis has zero errors/warnings and 23 infos. Full Python suite: 56 tests, 3 Linux compiler/packaging-dependent skips. Structure, architecture, locked dependencies and formatting passed.
- Logs: `output/webdav-settings-{targeted,full,analyze}.log`. Tests include existing user changes, not HEAD alone. Cache/in-flight/ops/sync state remains static; continue P6.4 instantiation, discovery/snapshot separation and late-result protection after disposal.

## P4/P6: WebDAV runtime instances and request sessions (2026-10-02)

- `WebDavLibrarySource` receives settings reading, cache and transport through its constructor. Snapshot/in-flight caches, notifiers and sync tasks are instance-owned. Removed source/cache default singletons and resetOps/resetCacheForTesting/resetForTesting; tests use independent directories/instances without changing App.dataPath or appdata.
- `WebDavLibraryCache` receives a fixed path, no longer tracks global path changes, rejects reopening after disposal and closes the database on initialization failure. The source owns transport/cache/notifiers; disposal is idempotent and closes other resources even when transport disposal throws. Default transport closes its clients. Disposal does not wait for uncancellable custom-transport Futures; late completions must pass session checks.
- Async operations retain configuration sessions checked after network responses and before cache writes/notifications. Connection changes (including passwords and external imports) invalidate old sessions; new synchronization need not wait for old requests. Stale indexes/snapshots/chapter/metadata results cannot overwrite current cache/status. Schedule-only changes retain valid sessions.
- `app_runtime/webdav_library.dart` assembles appdata and runtime instances. The mounted app registers adapters and disposes its instance; remount replaces old callbacks. Settings receive services through a scope/constructor and check mounted after saving, avoiding late source registration. Six WebDAV business entries join the gate (42 total), the source imports comic_source_api, and the UI scope remains outside business exports.
- Added 9 session/disposal tests and 1 mount regression: instance isolation, disposal before sync starts, pending discovery/chapter/metadata cancellation, password changes sharing cache keys, external imports, schedule changes, disposal failure and remount/disable. Retained the 25 source-protocol and 7 settings tests. Final full-suite results are recorded below; platform/performance acceptance remains outstanding.
- P6.4 remains partial: directory discovery, snapshot building and concrete transport still share the source file. Continue responsibility separation; instantiation is not overall completion.
- Final validation: full Flutter suite 1003 passed; analysis zero errors/warnings and 23 infos; full Python suite 56 tests (3 Linux compiler/packaging-dependent skips). Formatting/structure/architecture/locked-dependency checks passed. Logs: `output/webdav-instance-{full,analyze}.log`. Worktree validation includes existing user changes; this commit contains only stage files and its changelog entry.

## P6: WebDAV discovery, snapshot and transport responsibilities (2026-10-02)

- Extracted six modules for transport, sessions, discovery, snapshot values/building and shared entry rules, all enrolled in business gates (48 entries total). The source file shrank from about 1200 to 657 lines without parts or implicit cross-file private state.
- Discovery receives only a session and canReuse predicate; the coordinator retains cache readiness/remote-version decisions. Discovery has no SQLite/repository dependency. Recursive metadata discovery, top-level fallback, eight nested levels and the 2000-directory budget remain. Snapshot building reads its session and preserves cover/chapter sorting, CBZ ranges and fallback behavior.
- The snapshot value owns format version 3 and the cache uses that definition. Existing fields and chapter IDs remain unchanged. Reused directory filtering/sorting and removed the old private snapshot's declaration-only listTags getter; the source still assembles display tags using the existing protocol.
- Added five database-free service tests: explicit cache reuse, directory budget, depth limit, metadata/chapter serialization round-trip and cancellation propagation. Retained source/session/settings/mount regressions; 47 targeted tests passed. Synchronization coordination and source adaptation still need separation; P6.4 remains partial.
- Final validation: full Flutter suite 1008 passed; analysis zero errors/warnings, 23 infos. Structure/architecture gates, full Python suite (56 tests, 3 Linux-tool-dependent skips), locked dependencies and formatting passed. Logs: `output/webdav-services-{targeted,full,analyze}.log`. Tests include existing user worktree changes, which are excluded from this commit.

## P6: WebDAV synchronization coordination and source adaptation (2026-10-02)

- Added WebDavLibrarySynchronizer for automatic-update decisions, injected time, run coalescing, separate index-ready/full-sync completion, incremental updates and progress. It receives settings/session readers, cache, snapshot storage and notification ports with no comic-source type dependency. Progress exposes only ValueListenable.
- Added WebDavLibrarySnapshotStore for memory/disk caches and in-flight read coalescing. Each synchronization uses a derived session, rejecting late commits after invalidation/disposal without cancelling unrelated caller-owned sessions. Source invalidation notifies after clearing old configuration storage and still invalidates old runs if that clearing fails.
- The source adapter is about 321 lines, retaining interface mapping/reads and resource assembly/disposal. Removed synchronization forwarding methods; runtime/UI/tests use the synchronizer directly. Both new entries are gated (50 total). P6.4 implementation separation has evidence; overall P6 data/performance/platform acceptance remains separate.
- Added five coordinator regressions: disabled/exact-boundary automatic sync, coalescing including in-flight force requests, early index availability, invalidation/replacement without stale results and caller-owned reads after coordinator disposal. Existing path/snapshot/configuration/mount tests remain.
- A filename replacement error during caller migration caused one full-suite compilation failure; it was fixed and its log retained as `output/webdav-coordinator-compile-failure.log`. Only the final rerun below counts as passing evidence.
- Final validation: full Flutter rerun 1013 passed; analysis zero errors/warnings, 23 infos. All 50 business-entry gates, structure checks, full Python suite (56 tests, 3 Linux-tool-dependent skips), locked dependencies and formatting passed. Logs: `output/webdav-coordinator-{full,analyze}.log`. Worktree tests include existing user changes; this commit includes only stage changes.

## P6: Application-sync transfer and data-participant boundaries (2026-10-02)

- Extracted DataSyncTransfer, DataSyncParticipant and DataSyncRemote ports. WebDavDataSyncTransfer owns version selection/archive naming/remote retention; WebDavDataSyncRemote wraps the client. DataSync no longer imports archive operations or directly notifies history/image-favorite managers.
- `app_runtime/data_sync_transfer.dart` assembles production participants and registers a lazy factory during core source setup without eagerly creating DataSync. DataSync.withTransfer supports explicit transfer injection. Preferences, scheduling, subscriptions and legacy debug/reset globals remain to be migrated.
- Upload/download close connections and clean owned temporary files in finally. Downloads use a private cache subdirectory and use remote names only for remote reads. Day/version naming and the existing delete-old-before-upload retention order remain; remote replacement is not claimed atomic. Cleanup failure can still report failure after a transfer committed.
- Downloads report whether data was applied; unchanged remote versions return false so DataSync retains pending edits. Production archive import still returns void, so this extraction retains its legacy assumption that a returned import applied data. A separate fix must propagate internal version-check no-ops to avoid incorrectly clearing pending edits.
- Added six transfer regressions: naming/retention/exclusions, upload failure cleanup, version skip, participant no-op, notification ordering/private paths and import failure cleanup. Targeted 47 and full Flutter 1019 passed; analysis zero errors/warnings, 23 infos. Structure/52 business-entry gates, full Python suite (56 tests, 3 Linux-tool-dependent skips), locked dependencies and formatting passed.
- Logs: `output/data-transfer-{targeted,full,analyze}.log`. Tests include existing user worktree changes; this commit contains only stage files.

## P6: Preserve pending edits when an old archive is skipped (2026-10-02)

- Separate fix after transfer extraction: a newer remote filename can contain an embedded dataVersion no newer than local data. Import skips that archive, but the old void return was treated as applied and could clear pending edits. importAppData now returns false for embedded-version skips and true when its original import path completes; exceptions still propagate.
- The runtime participant forwards the result. Skipped imports no longer emit success notifications or update lastSyncTime through the transfer service, and DataSync retains pending edits. Manual imports without version checking can still apply older versions; archive formats and replacement/rollback paths are unchanged.
- Added five real ZIP/controller regressions for old/equal skips, newer application, manual older imports and DataSync pending retention/clearing. Together with transfer/favorites-import coverage, 14 targeted tests passed.
- Final validation: full Flutter suite 1024 passed; analysis zero errors/warnings, 23 infos. Structure/architecture, full Python suite (56 tests, 3 Linux-tool-dependent skips), locked dependencies and formatting passed. Logs: `output/import-result-{targeted,full,analyze}.log`; worktree tests include user changes excluded from this commit.

## P6: Injected sync preferences, clocks and subscriptions (2026-10-02)

- Extracted DataSyncController with preference storage, transfer factory, settings/implicit persistence, change subscription, clock and timer ports. It imports no appdata or feature managers and has no static singleton/debug/reset state. The new business gate brings the total to 53 entries.
- SyncPreferenceStore now uses explicit settings access and an implicit-map provider, with Appdata adaptation in app_sync_preferences.dart. The provider reads the current map after startup/import replacement instead of retaining an obsolete map. Legacy keys and rollback-checkpoint behavior remain.
- Subscriptions return individual release callbacks. stop retains observation for edits while detached; dispose releases it. Subscription failure restores the started state for retry, while the subscription provider owns atomic setup/rollback. The legacy application adapter now cleans up failed setup.
- DataSync remains a temporary composition facade for static mode/interval, singleton access and legacy test hooks, inheriting the same controller implementation. It has not been retired; production sync is not yet globally independent. Migrate callers/tests before removing the facade.
- Added six controller regressions without appdata/filesystem setup: instance/subscription isolation, stop/dispose, independent clock/timer scheduling, subscription retry, failed draft-transfer rollback and implicit-map replacement. Alongside existing schedule/window/import tests, 55 targeted tests passed.
- Final validation: full Flutter suite 1030 passed; analysis zero errors/warnings, 23 infos. Structure/53 business-entry gates, full Python suite (56 tests, 3 Linux-tool-dependent skips), locked dependencies and formatting passed. Logs: `output/sync-controller-{targeted,full,analyze}.log`. Worktree tests include user changes; only stage files/changelog are committed.

## P6: Explicit sync controllers for UI and window bindings (2026-10-02)

- Added DataSyncScope. The application supplies the same controller to status summary and sync settings; the scope does not dispose it. ListenableBuilder moves summary subscriptions when the controller changes.
- BackgroundSync.platform and SyncWindowBinding require a controller. Resume checks, background scheduling and window shutdown share the application-held instance. Each shutdown captures its controller before asynchronous preparation, avoiding a wait on a replacement instance.
- Schedule fields read SyncConfiguration.intervalOptions directly. Existing window tests now pass their controller explicitly while retaining their legacy test composition.
- New scope/summary regressions cover replacement, button routing, status changes, listener removal, non-owning scope lifecycle and a clear error for missing composition. All 14 targeted tests passed.
- This is a caller-migration increment: main still obtains the legacy DataSync instance. Headless/bootstrap/follow-up/reader-close callers and legacy test hooks remain. P6.5/P6.6/P8.1 stay incomplete.
- Final validation: full Flutter suite 1032 passed; analysis zero errors/warnings, 23 infos. Structure/53 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-scope-{targeted,full,analyze}.log. Worktree tests include user changes excluded from this commit.

## P6: Instance-owned follow-up runtime without a sync-domain dependency (2026-10-02)

- FollowUpdatesRuntime owns its background service, notifier and external subscription. Folder/busy queries, download wait, task factory, error handling and subscription setup are injected. Removed global followUpdatesService/followUpdatesChanges and global start/stop functions.
- app_runtime/follow_updates.dart connects existing favorites notifications and an explicit DataSyncController. MyApp owns/disposes the runtime; FollowUpdatesScope supplies it to views. Preview/page subscriptions move on scope replacement and refresh their data; cancellation targets the current runtime.
- Failed startup stops timers and releases acquired subscriptions before retry. Repeated start/stop do not duplicate subscription/release. Late downloads from a stopped run cannot create tasks, and disposal cancels owned tasks. The favorites manager's single callback registration and foreground FollowUpdateJob global state remain future lifecycle work.
- Added four runtime regressions and extended the two-preview test for scope replacement/unsubscription; all 14 follow-update tests passed. Removed the follow_updates → sync allowed edge and enrolled the runtime business entry, bringing the gate to 54. P6.5/P6.6/P8.1 remain incomplete.
- Final validation: full Flutter suite 1036 passed; analysis zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/follow-runtime-{targeted,full,analyze}.log. Worktree tests include user changes excluded from this commit.

## P6/P8: Retire static sync test hooks (2026-10-02)

- Removed DataSync.debugNow/debugUploadOverride/debugDownloadOverride, unused static mode/intervalMinutes/intervalOptions accessors and the withTransfer test constructor. Controller uploadNow/downloadNow are private; tests no longer override them to bypass real transfer execution.
- Queue/window tests use independent memory settings and ControlledSyncTransfer. Transfer failures cross the injected port and are converted to Res by the real controller. Schedule tests inject clocks/timers directly instead of replacing Zone timers; persistence/restart scenarios still read a real temporary implicitData.json.
- Schedule fixtures own the application-data subscription, preserving detached-pending/repeated-start/retry/rollback scenarios. Archive tests construct controllers with real ZIP import transfers. Download fixtures explicitly return false for an unapplied snapshot instead of relying on an override leaving internal state untouched.
- All 32 queue/schedule/window targeted tests passed. Application singleton composition, production subscription adaptation and remaining reader reset callers await migration; P8.1 stays incomplete.
- Final validation: full Flutter suite 1036 passed; analysis zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-hooks-{targeted,full,analyze}.log. Existing user changes participate in worktree tests but are excluded from this commit.

## P6/P8: Retire the production sync singleton and reset entry (2026-10-02)

- Deleted features/sync/data_sync.dart and transfer-factory registration. app_runtime/data_sync.dart exposes an inert factory without a static controller. Interactive and headless entrypoints create their own controller explicitly.
- Callers own CoreBootstrap and inject the comic-source save callback. Removed the default global bootstrap and parameterless init cache; CoreBootstrap.start still coalesces startup on the same instance.
- MyApp borrows the host controller for window/background/settings/summary/follow-up consumers. Unmount only stops timers, retaining observation for late reader writes and edits between mounts; the process host owns final disposal. Initialization failure and normal headless completion dispose it. Forced-process-exit and in-flight-disposal boundaries are unchanged.
- Reader requires onClosed. Four reader entrypoints obtain the host callback from ReaderSessionScope; the existing ReaderSession drain/completion chain dispatches it. Removed sync resets from reader tests, staging only our callback migration in the user-modified viewport test.
- Added actual reader-unmount notification and application-adapter inert/start/stop/dispose regressions. The new adapter test initially read an uninitialized App.dataPath; fixed its setup and verified it independently. The other 24 targeted tests passed. Enrolled the old sync file in retirement checks and removed the reader → sync allowed edge.
- P6.5/P6.6 still need configuration-failure recovery, in-flight cancellation and full restart/no-echo acceptance. P8.1 sync compatibility is retired, but local-comics reset/debug and aggregate-export review remain. Actual CLI-process, five-platform and fixed-device performance evidence is still outstanding.
- Final validation: full Flutter suite 1038 passed; analysis zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-owner-{targeted,adapter,full,analyze}.log. Worktree tests include existing user changes; only this stage is committed.

## P6: Sync configuration failure recovery and disposal checks (2026-10-02)

- Fixed rollback persistence throwing out of finally and leaving _configuring=true indefinitely. Waiting for old work and capturing checkpoints now run inside the protected flow; a separate finally always releases the configuration flag. Rollback failure returns Res with both original and recovery errors.
- No checkpoint means no attempted restoration. Existing checkpoints retain old preferences and pending edits made during configuration. Disposal after draining old work prevents draft application; disposal during initial transfer/save prevents committing the new schedule and attempts old-configuration restoration.
- Added five regressions: repeated settings/implicit-save and rollback failures followed by retry, checkpoint-read failure/retry, disposal while awaiting an old transfer, and disposal during a draft transfer. The initial 32 targeted queue/schedule/controller tests passed; the additional disposal case is included in the full suite.
- This repairs configuration control flow, not durable atomicity. Failed persistence recovery is reported and cannot guarantee restored disk contents. Configuration rollback cannot undo an already committed remote upload or applied data import. In-flight cancellation/import boundaries and final P6.5/P6.6 acceptance remain open.
- Final validation: full Flutter suite 1043 passed; analysis zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-recovery-{targeted,full,analyze}.log. Worktree tests include user changes; only this stage is committed.

## P6: Sync cancellation propagation and import commit boundary (2026-10-02)

- The controller creates a RequestScope per actual transfer and cancels it on dispose. Queues still await operation cleanup; no Future race abandons unfinished file writes in the background.
- Transfer and import participant ports receive the scope explicitly. Cancellation closes the operation-owned remote through an idempotent closer shared with finally. Checks after downloads prevent late bytes from starting imports. Upload checks around preparation/listing and remote operations prevent subsequent work after cancellation.
- Added importSyncAppData, checking after acquiring the AppDataOperations queue and after archive extraction/parsing, before creating replacement backups. After this boundary the existing replacement/commit/rollback finishes without interruption. Applied imports still notify and record completion rather than pretending a local commit did not occur.
- Added five regressions: late-download cancellation, upload cancellation after listing, post-commit-boundary import completion, queued-import cancellation and post-validation cancellation. Controller tests assert scope cancellation on dispose. Two initial filesystem tests used unreliable timing; explicit stage signals resolved them and all 49 targeted tests passed.
- Remaining limits: remote requests already sent may have uncertain commit outcomes; the existing delete-before-upload retention protocol is not atomic. Local imports past their commit boundary are not forcibly interrupted. Actual server-disconnect/CLI-process and final platform/performance evidence remain open; P6.5/P6.6 are not globally complete.
- Final validation: full Flutter suite 1048 passed; analysis zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-cancel-{targeted,full,analyze}.log. Worktree tests include user changes excluded from this commit.

## P6: Retain remote recovery points until upload acknowledgement (2026-10-02)

- Reordered upload so it no longer deletes daily/oldest archives before writing. It lists the directory, generates the same archive format/name, awaits successful write acknowledgement, and only then cleans up. Export/local-read/list/write failures do not actively delete previous files in this flow.
- Preserved first-daily and oldest-at-10 selection. A set deduplicates candidates and excludes the just-uploaded name, preventing duplicate deletes or removal of the new same-name archive. No fields, migration or client-version requirement were added.
- Cancellation after write acknowledgement prevents cleanup. Cleanup failure remains a failed result without updating lastSyncTime, retaining controller pending for retry. A new recovery point may already exist remotely; failure does not imply no remote commit. Old clients can read the unchanged day-version.venera naming and archive contents.
- Added four regressions for post-write cleanup failure, post-acknowledgement cancellation, same-name protection and duplicate candidates. Strengthened failed-write preservation and call-order assertions. All 40 related transfer/controller/schedule tests passed.
- Remaining limits: concurrent clients, same-name overwrites and lost server responses are not remotely atomic; cancellation cannot undo sent operations. Partial cleanup leaves extra history; reverting code cannot restore deleted historical files. Inspection also identified lexical archive sorting whose numeric-version correctness needs a separate next-stage verification. P6.5/P6.6 remain under overall acceptance.
- Final validation: full Flutter suite 1052 passed; after the null-aware collection syntax cleanup, all 13 transfer tests passed again and analysis returned to zero errors/warnings, 23 infos. Structure/54 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-retention-{targeted,full,final,analyze}.log. User changes participate in worktree tests but are excluded from this commit.

## P6: Numeric archive ordering and shared selection rules (2026-10-02)

- Fixed lexical ordering that ranked 20-9.venera above 20-10.venera, causing local version 9 to skip a newer remote archive. Day fields also compare numerically across digit boundaries.
- Extracted compareDataSyncArchiveNames. Downloads choose the maximum; retention selects daily/global oldest candidates from the same ascending order. Server listing order no longer decides the daily cleanup target. Existing .venera filtering, version checks, archive format and written names remain; no migration is introduced.
- Numeric runs compare trimmed lengths then digits, avoiding integer overflow for long remote input. Text runs retain ordinal order and equivalent numeric spellings use the original name as a tie-breaker. Unversioned legacy archives remain readable; numeric runs in legacy names also use natural order. Older clients can read the files but do not gain this sorting fix.
- Added six tests covering numeric dates/versions/leading-zero ties, pairwise and reverse ordering of mixed names, long numbers, download selection across version/day boundaries, retention order and unversioned archives (some scenarios share tests). All 19 ordering/transfer targeted tests passed; business entry enforcement now covers 55 entries.
- Conflict resolution and multi-client write atomicity are unchanged. Final P6.5/P6.6 protocol and restart/no-echo acceptance remains open.
- Final validation: full Flutter suite 1058 passed; analysis zero errors/warnings, 23 infos. Structure/55 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/sync-order-{targeted,full,analyze}.log. Existing user changes participate in worktree tests but are excluded from this commit.

## P2/P6: Headless sync outcomes and exit-code adaptation (2026-10-02)

- Fixed webdav up/down ignoring Res failures, printing success and exiting zero. runHeadlessSyncCommand receives configuration validity and upload/download ports, emits outcomes and returns an exit code. The entrypoint still owns controller lifetime and process exit.
- Successful running/success messages and the [CLI PRINT] JSON prefix remain; no-new-data downloads remain successful. Missing configuration, invalid subcommands, failed results and thrown service errors emit error/exit 1 without a success terminal. Serialization now lives in Flutter-independent headless_output.dart.
- Added ten adapter tests, partly using the real controller with controlled transfer ports, covering waiting/failure/preflight/exception/no-op behavior. Six real Dart subprocess probes invoke production adapter/serialization functions and verify stdout JSON lines plus actual exit codes.
- Probes use controlled services without starting the Flutter application or accessing user data. They do not replace full headless-app plugin/argument/data-directory acceptance. Partial-failure/exit behavior of other CLI commands still needs review; P2.3 remains incomplete. Protocol boundary: successful messages are unchanged; previously false success/0 failures now become error/1 under the existing status/exit-code convention.
- Final validation: full Flutter suite 1074 passed; analysis zero errors/warnings, 23 infos. Structure/55 business-entry gates, Python 56 tests (3 platform-tool skips), dependency lock and formatting checks passed. Logs: output/cli-sync-{targeted,process,full,analyze}.log. User changes participate in worktree tests but are excluded from this commit.

## P2/P6: CLI argument preflight and script-update failures (2026-10-02)

- A pure parser validates commands, subcommands and comic selectors before core startup; the log flag may appear among arguments. Missing/extra/invalid arguments produce error/1 before application-data access. Previously ignored extra arguments are now rejected; both user guides document this compatibility change.
- The source adapter snapshots check results and pending updates. Thrown/partial check failures no longer report no-update success; individual failures do not stop remaining sources. Counters and optional checkErrors determine a nonzero failure exit code.
- Subscription missing-folder, missing-comic and update failures now set exit code 1. Command exceptions emit error, and finally cleans the sync controller and source-save handler. Real subscription-service branches still require further acceptance.
- Added 27 tests covering grammar, empty/check-failed/thrown outcomes, mixed failures and immutable snapshots, including 5 controlled Dart subprocess probes checking preflight, JSON output, one terminal result and actual exit codes. Full Flutter headless startup/plugins/data directories remain unverified; P2.3 stays partial.
- Validation: all 1101 Flutter tests passed; 7 adapter tests passed again after null-aware syntax cleanup; analysis has zero errors/warnings and 23 infos. Structure and 55 business entries, 56 Python tests (3 skipped), Git dependency locks and formatting passed. Logs: output/cli-source-{targeted,full,final,analyze}.log. Workspace tests include user changes; this commit contains only this stage.

## P2/P7: subscription CLI orchestration and completion boundary (2026-10-02)

- Extracted headless_subscription_command.dart with selected-comic update, folder-progress and updated-list ports to unify progress/summary/terminal output and exit codes. headless.dart maps existing services and comic fields, removing duplicated branch orchestration.
- Missing configuration/comics stop subsequent calls. Individual/batch failures retain result lists with error/1. Service, stream and list-read exceptions preserve the original error for logging and emit one error terminal result. Stream and result reads are awaited.
- Premature batch completion no longer reports success: missing initial progress or current < total produces incomplete error without a success-list read. Single-comic cancellation maps to ProgressError/error/1; this is the existing CLI protocol, not completion of project-wide structured cancellation work.
- Removed both fixed 500 ms delays: updateComic commits updateInfo/updateUpdateTime/updateCheckTime synchronously through the repository, and folder streams close after tasks finish. Results can be read from committed state without timing guesses.
- Added 12 adapter tests and 6 real Dart subprocess protocol probes; 32 targeted tests passed including existing follow-update regressions. Probes use controlled ports and do not verify native Flutter startup, real composition or global-manager isolation. P2.3 stays partial; indirect UI barrel dependencies remain open.
- Final validation: all 1119 Flutter tests passed; analysis reports zero errors/warnings and 23 infos. Structure and 55 business entries, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting passed. Logs: output/cli-subscription-{targeted,full,analyze}.log. Workspace tests include user changes; they are excluded from this commit.

## P7: split comic-source parser by capability (2026-10-02)

- Moved 26 capability methods into 9 independent classes: account, explore, category, search, favorites, images, comments, comic and metadata. parser.dart shrank from 1349 to 282 lines, retaining declaration/version/key validation, JS installation/rollback, composition and loadData; the largest unit is 266 lines. These are independent libraries, not part/mixin fragments, and do not depend on the entrypoint.
- SourceParserContext owns immutable key/name, optional property access and shared comic-list normalization. This fixes old callbacks reading the new _key after parser reuse. Callback names/argument order, read/write JS bridge selection, Res/re-login behavior and disk formats remain unchanged. Exceptions moved to a separate library and are re-exported by parser.dart.
- Added two real QuickJS regressions: reuse one parser for two sources and execute search/explore/category/favorites/details/images/comments with distinct identity; verify absent optional hooks, malformed data and JS errors retain failure semantics. Initial fixtures lacked minAppVersion and leaked function handles returned by JS assignments; explicit version and void assignment fixed these tests without changing production version comparison.
- All 112 source-module targeted tests passed. Added 11 capability/context/exception entries to the dependency gate, now 66. P7.1 has implementation evidence; P7.2 still needs full account/re-login, cursor and dynamic-category matrices. P7.5 structured errors/cancellation remain open; this is not whole-P7 completion.
- Final validation: all 1121 Flutter tests passed; analysis has zero errors/warnings and 23 infos. Structure and 66 business entries, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting passed. Logs: output/parser-split-{targeted,full,analyze}.log. Workspace tests include user changes; this commit contains only this stage.

## P7: account, cursor and category execution matrix (2026-10-02)

- Added 9 synthetic-source cases in source_capabilities_test.dart using real QuickJS/production init.js and temporary directories. They verify special-character login arguments/persisted identity, webview/cookie/logout callbacks; no unauthenticated favorite request, one re-login, failed/repeated-expiry termination and folder operations; search/explore/ranking cursors, dynamic-option arguments, legacy/current category targets and invalid-loader rollback.
- The first run reproduced categories[0] throwing for empty category lists and preventing source installation. source_category_parser.dart now skips empty lists before format detection. Other category behavior, random selection and dynamic-function ownership were not changed in this stage.
- Added source_capability_matrix.zh/en.md to record executed evidence and gaps. P7.2 remains partial: valid dynamic-function execution/release, archives/votes/metadata and full cancellation/re-login combinations remain open. Tests use no network/personal source data and explicitly skip when the native library is unavailable.
- Validation: all 121 targeted source tests and 1130 Flutter tests passed; analysis has zero errors/warnings and 23 infos. Structure/66 business entries, 56 Python tests (3 platform-tool skips), dependency locks and formatting passed. Logs: output/source-matrix-{targeted,full,analyze}.log. User workspace changes participate in testing but are excluded from this commit.

## P4/P7: explicit ownership of dynamic-category native callbacks (2026-10-02)

- A real QuickJS dynamic-category execution followed by engine close reproduced reference leak (output/dynamic-lifetime-before.log). The old JSAutoFreeFunction finalizer neither tied release to source removal nor released temporary callback references from the category document.
- Added JsCallbackScope with paired retain/release, idempotent disposal and StateError for calls after release. Scopes belong to the engine that created them and surviving scopes are released before engine close. Dynamic categories use protected closures; temporary category-document references are released in finally. JS loader names, arguments and category formats are unchanged.
- Parser failure/rollback releases the new scope; success transfers it to ComicSource. The manager releases old callbacks on replacement commit, removal and reload; failed replacement preserves old callbacks. The source constructor's optional scope leaves non-JS sources unchanged; the test Fake implements the lifecycle method.
- Added 4 real-native regressions: execution/close, rejection after removal, rejection after engine shutdown/reinitialization, and three failed replacements preserving the old loader followed by a committed replacement invalidating it. All 125 source tests passed. Updated both capability matrices; settings/image/UI JSAutoFreeFunction ownership remains a separate open audit, not whole-JS-lifecycle or whole-P7 completion.
- Final validation: all 1134 Flutter tests passed; analysis has zero errors/warnings and 23 infos. Structure/66 business entries, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting passed. Logs: output/dynamic-lifetime-{before,targeted,full,analyze}.log; before intentionally reproduces the pre-fix failure, the others record final validation. User workspace changes participate in testing but are excluded from this commit.

## P4/P7: source settings callbacks and dynamic snapshot scopes (2026-10-02)

- Static settings parsing reuses the source JsCallbackScope through a retain-callback port in normalizeComicSourceSettings. Production parsing no longer creates finalizer wrappers and releases temporary JS documents, including ignored fields, in finally. The normalizer's default wrapper remains compatible with existing standalone callers.
- JsCallbackScope now supports children: snapshots release independently, while parent disposal releases all children. getSettingsDynamic explicitly requires a caller scope. The page releases old snapshots on rebuild, collapse and disposal rather than accumulating getter-created functions until source removal. Independent readers do not invalidate one another. Getter failure still falls back to source-owned static settings.
- Added 4 real QuickJS regressions: static callback invalidation on removal, independent snapshots and 20 create/release cycles, getter-error fallback and repeated parse-failure cleanup. All 129 source tests passed. Native close checks cover reference release; dedicated Widget tests of rebuild/collapse/disposal remain open. Image/JS UI JSAutoFreeFunction uses are still unmigrated, so whole-project lifecycle acceptance remains open.
- Final validation: all 1138 Flutter tests passed; analysis has zero errors/warnings and 23 infos. Structure/66 business entries, 56 Python tests (3 platform-tool skips), dependency locks and formatting passed. Logs: output/settings-lifetime-{targeted,full,analyze}.log. Workspace tests include user changes; this commit contains only this stage.

## P4/P7: settings-page snapshots and async callback acceptance (2026-10-03)

- Added 5 Widget tests using production ComicSourcePage/JsCallbackScope and controlled JSInvokable objects. They verify one release per snapshot across theme rebuild, collapse, reopen and unmount, filling the previous page-lifecycle evidence gap. These complement native QuickJS tests and do not independently prove native execution.
- First reproduced setState after _CallbackSettingState disposal while a callback was pending. Finally now checks mounted. Synchronous and asynchronous failures preserve the original error in logs and notify through the message port only while mounted. Running callbacks reject duplicate taps; failures restore retryability; late failures do not manipulate an unmounted page.
- All 5 targeted Widget tests passed: snapshot release, late success, synchronous/asynchronous failure and retry, rapid duplicate taps and late failure. Both capability matrices are updated. Multi-page/source-replacement interaction and image/JS UI callback migration remain open; P4/P7 are not declared complete.
- Final validation: all 1143 Flutter tests passed; after fixing a test brace hint, analysis has zero errors/warnings and 23 infos. Structure/66 business entries, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting passed. Logs: output/settings-widget-{targeted,full,analyze}.log. User workspace changes participate in testing but are excluded from this commit.

## P4/P7/P8: custom image processing and callback release (2026-10-03)

- Extracted reader_image_processing.dart. The provider still reads files/network streams, while an independent function executes/adapts/cancels processImage. Removed both provider finalizer wrappers and duplicate Future branches, retained process/cancel functions in an operation scope, promptly released borrowed references and ended ownership in finally.
- waitForReaderImageProcessingResult takes an explicit cancellation signal. Late discarded results and results rejected by checkStop release unconsumed JSRef values. The debugWaitForReaderImageProcessingResult test-only wrapper was removed; existing tests call the production function.
- Added 7 real QuickJS cases for existing ArrayBuffer, Promise and {image,onCancel} forms, argument order, synchronous/asynchronous errors, exactly one cancel call, ignored fields and invalid-result fallback. Initial fixtures used Uint8Array; they were corrected to the actual ArrayBuffer bridge protocol without changing production semantics. Added 2 controlled-reference tests for exactly-once late/stopped-result release; all 13 targeted tests passed.
- Existing async-null-to-empty and other-invalid-result-to-original-byte behavior remains. Cancellation returns promptly and cannot force termination of uncooperative third-party JS promises or undo side effects. Outstanding promise lifetime during engine shutdown, network image configuration and UI callbacks remain open.
- Final validation: all 1152 Flutter tests passed; analysis has zero errors/warnings and 23 infos. Structure/66 business entries, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting passed. Logs: output/image-callback-{targeted,full,analyze}.log. Workspace tests include user changes; this commit contains only this stage.

## P4/P7: JS dialog callback and resource lifetime (2026-10-03)

- JsUiApi action/loading/input dialogs now own independent JsCallbackScope instances instead of JSAutoFreeFunction. Route completion and widget disposal release them idempotently. Loading registry cleanup checks scope identity so old cleanup cannot delete a reused id.
- Shared DialogResourceScope binds cleanup to actual unmount. Loading controllers clear closed callbacks; programmatic close does not cancel, while button/back/barrier/unmount cancel at most once. Input controllers are disposed with their dialog. Action/input requests also resolve on Navigator unmount, avoiding bridge Promises waiting indefinitely for route completion.
- Action callbacks await asynchronous results and reject duplicate execution. Errors preserve original logging and late completion never updates unmounted widgets. Ignored action/cancel results release JSRef. JS input validation remains synchronous; validation errors stay visible and retryable. Shared asynchronous input confirmation now guards mounted state and restores state after failure.
- Fourteen controlled JS UI cases, one real QuickJS/widget case and five existing message cases pass (20 total). Coverage includes dismissal paths, id reuse, retries, late success/failure, native asynchronous action/cancel return-reference cleanup and input unmount completion. Native tests alternate real event-loop progress with Flutter fake frames; correcting test scheduling preserved actual native execution.
- Normalization compatibility still retains a finalizer wrapper; engine exit with pending Promises remains to validate. This does not complete all P4/P7/P8 acceptance.
- Final validation: all 1167 Flutter tests pass; analysis has zero errors/warnings and 23 infos. Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting pass. Logs: output/js-ui-{targeted,native,full,analyze}.log. Tests include existing user edits; the commit includes only this stage.

## P1/P8: retire normalization test entrypoints and finalizer wrapper (2026-10-03)

- Repository reference search found nine debugNormalizeComicSource forwarders used only by comic_source_settings_test.dart. Tests now directly import normalization.dart/models.dart; the manager drops all nine forwarders and two redundant imports. The public source barrel no longer indirectly exposes these test utilities.
- The final JSAutoFreeFunction use was the normalization fallback. Both production callers (static metadata and dynamic settings) already explicitly supplied JsCallbackScope.retain. Removed the wrapper/Finalizer and fallback; retainCallback is required and returns a typed callable, preventing omitted ownership at compile time.
- Existing normalization cases still validate conversion. The callback case uses production JsCallbackScope with controlled JSInvokable to check invocation after borrowed-document release, exactly-once destruction, idempotent disposal and rejection after closure. Invalid settings never invoke retention. All 134 source-module tests pass, including existing real QuickJS settings/replacement/failure-cleanup cases.
- This evidence-backed deletion does not replace the full P1 candidate/dependency/artifact inventory. Other reset/debug entrypoints and P8 lint restoration remain open.
- Final validation: all 1167 Flutter tests pass; analysis has zero errors/warnings and 23 infos. Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), Git dependency locks and formatting pass. Logs: output/normalization-cleanup-{targeted,full,analyze}.log. Tests include user edits; this commit contains only this stage.

## P8: restore collection type gate and chapter read marks (2026-10-03)

- Enabling collection_methods_unrelated_type found 25 diagnostics: 23 numeric SQLite Row lookups, one normalization test querying an integer in a string-keyed Map, and one normal chapter view querying an integer in Set<String>. No dynamic casts or ignores were added to bypass the rule.
- SQLite Row supports numeric indexing, so those findings did not mean failed reads. Repositories/cache/import and corresponding tests now use column names, with total aliases for aggregates, reducing column-order coupling. The normalization test asserts the complete key list to continue checking invalid-key filtering.
- Fixed missing read styling in normal chapters by reading the 1-based string history index. Two widget regressions cover forward/reversed order, correct read styling and click index, and rebuilding with cleared/replaced history. Grouped history format is unchanged.
- Warning severity makes the existing CI --fatal-warnings gate enforce this rule without changing other info handling. All 81 targeted tests pass across chapters/history/image favorites/local repository/import/transactions/cache/normalization. use_build_context_synchronously remains open; P8.2 is still partial.
- Final validation: all 1169 Flutter tests pass; analysis has zero errors/warnings and 23 infos. Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. A temporary invalid fixture produced a warning and nonzero dart analyze --fatal-warnings exit, then was removed. Logs: output/collection-lint-{analyze,targeted,final-analyze,full,gate-probe}.log; analyze is the initial restored-rule diagnostic baseline. Tests include user edits; this commit includes only this stage.

## P4/P6/P8: import presentation boundary and async context audit (2026-10-03)

- Enabled use_build_context_synchronously as info repository-wide, exposing 85 findings. This stage resolves the 21 import-file findings; the remaining 64 are inventoried by file in async_context_audit.en.md. Analysis currently reports 87 infos (23 existing + 64 outstanding), not a clean lint rollout. Raise warning severity after resolving all findings; none are suppressed.
- Extracted injectable ImportComicPresentation for messages/loading/PDF task views. The default implementation synchronously resolves the current root Navigator context and checks mounted for every display. Missing roots omit UI while existing services retain task ownership. ImportComic no longer directly accesses BuildContext or force-unwrapped App.rootContext. Selection/copy/registration and data protocols remain intact.
- PDF dialogs use DialogResourceScope so normal close or Navigator unmount finishes the view wait and returns the current result. Unfinished tasks remain owned by PdfImportTasks and are not cancelled by window disposal. Loading views reuse existing close/cancel cleanup and ignore late progress after disposal.
- Four lifecycle cases cover import completion without a root, loading unmount/root recreation, and hidden/visible-then-unmounted PDF views that preserve task completion and selection cleanup. An initial cross-fake-async wait in test teardown hung; corrected cleanup passes. All 91 import-directory tests pass.
- This adapter remains a presentation dependency of import orchestration; it does not establish fully UI-free import business code. Other context findings, partial storage commits and native-platform acceptance remain open.
- Final validation: all 1173 Flutter tests pass; analysis has zero errors/warnings and 87 infos as broken down above. Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. Logs: output/context-import-{presentation,targeted,final-analyze,full}.log. Tests include user edits; this commit contains only this stage.

## P4/P5/P8: comment requests, interactions and page lifetime (2026-10-03)

- Comic/chapter/embedded-chapter comments deduplicate initial and pagination requests. Future.sync routes synchronous loader failures through asynchronous error handling. Initial failures retry and clear on success; pagination failures expose explicit retry instead of repeatedly requesting failed pages during rebuild.
- Successful sends increment the request generation and reset the list, preventing late old pagination from contaminating refreshed results. Same-frame duplicate sends execute once. Send/like/vote preserve error logging, restore busy state in finally and avoid updating disposed pages/editors.
- Comic/chapter pages dispose their TextEditingController. Embedded comments now own/dispose one ScrollController instead of creating one per build. All eight comment context diagnostics are resolved, along with setState/controller lifetime issues not detected by that lint.
- Twenty-four widget cases cover all three views: initial deduplication, synchronous failure/retry, pagination failure/retry/refresh generation, duplicate sends/failure retry/late success and failure, and like/vote retry with late success. Production widgets use controlled source ports; this does not replace native JS vote/cancellation coverage.
- Final validation: all 1197 Flutter tests pass; analysis has zero errors/warnings and 79 infos (23 existing + 56 remaining context findings). Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. Logs: output/comments-lifecycle-{targeted,full,final-analyze}.log. Duplicate comment flows still need consolidation; this does not complete all P5/P7/P8. Tests include user edits; the commit contains only this stage.

## P4/P8: source login pages and asynchronous error recovery (2026-10-03)

- Password/cookie login now uses async/try/catch/finally, rejects duplicate submissions, preserves logging/user-visible failures, and skips messages/navigation/State updates after unmount. Cookie validation explicitly awaits saveData before leaving; save failures keep the page open and restore retry.
- Re-login deduplicates by source key and clears busy state on success, service failure or thrown errors. Source settings await persistence on login-route return, report failures, and only rebuild mounted views, also fixing late setState not identified by the original lint.
- External-editor reload dialogs use the already checked page context; WebView return checks login-page lifetime. An unavailable desktop WebView stops after reporting instead of opening anyway. Close handling is idempotent and does not pop after login-page disposal.
- Eight widget cases cover password/cookie duplicate taps, failure/retry, late success/failure, cookie persistence wait/failure recovery, and re-login deduplication/late errors. Native WebView plugins, concurrent cookie/localStorage collection and route identity still require dedicated acceptance. This does not complete all web-login lifecycle work or change source login functions' own side effects.
- Final validation: all 1205 Flutter tests pass; analysis has zero errors/warnings and 71 infos (23 existing + 48 remaining context findings). Structure/66 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. Logs: output/source-login-{targeted,full,final-analyze}.log. Tests include user edits; the commit contains only this stage.

## P2/P6/P8: local export orchestration and staging ownership (2026-10-03)

- Inspecting local-library context findings exposed shared fixed comics_export directory/ZIP paths and inconsistent cleanup on cancellation/save failure. Extracted comic_export_service.dart: createTemp allocates a unique workspace, content and final ZIP are separate, and export/compress/save share one try/finally. Cleanup waits for save completion; concurrent operations no longer delete each other's files or old fixed cache paths.
- The page supplies format/compress/save ports, progress and errors, and closes its dialog in finally. Cancellation/page disposal prevents the next step or save window. Already-started export/compression/system save cannot be forcibly aborted and is cleaned after completion. Cleanup failures are logged without replacing the main outcome; this does not guarantee deletion under all filesystem failures.
- Duplicate or case-colliding titles receive sequential (2) suffixes instead of silent overwrite. Single filenames and the final comics_export.zip name remain. WebDAV archive messages only target mounted views while preserving return/cancellation semantics. All three local-library context findings are resolved.
- Ten real-temporary-file/controlled-port tests cover save ownership, name collisions/ZIP location, export/compress/save failure, export/compress cancellation, empty/pre-cancelled work and concurrent isolation, including preservation of old fixed cache directories. These do not replace native PDF/EPUB/ZIP or system-save UI acceptance. History/image-favorites findings remain in the audit.
- Final validation: all 1215 Flutter tests pass; analysis has zero errors/warnings and 68 infos (23 existing + 45 context findings). Structure/67 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. Logs: output/local-export-{targeted,full,final-analyze}.log. Existing user changes participate in working-tree tests but are excluded from this commit.

## P4/P6/P8: sync-window waiting and exit-guard cleanup (2026-10-03)

- SyncWindowBinding owns its upload loading controller and closes it in finally after completion/failure. Disposal schedules closure after tree finalization to avoid synchronously modifying a surviving Navigator. Presentation resolves/checks the current root context; no root still waits for upload without showing a dialog.
- showLoadingDialog adds cancelOnDismiss (default true, preserving existing task semantics). Shutdown waiting sets false: its button can force exit, but back/disposal cannot be mistaken for that action. Close checks Navigator.mounted and route.isActive. An existing test reproduced the queued-but-unbuilt dialog being closed after Navigator disposal and hitting a route-lock assertion; the fix passes that case.
- Import/download release handles are cleared before invocation for idempotency; import release is attempted even if download release throws. Successful waits retain guards until disposal; failed waits release guards so window close can be retried.
- Eight new cases (four window, four shared-dialog), together with existing cases, pass 23 targeted tests: completion/wait failure/binding removal with a retained window/no root Navigator, plus button/back/disposal/unbuilt dialog. Checks cover exactly-once cleanup and no premature forced exit on binding removal. Window cases run on Windows and explicitly skip elsewhere; this is not native cross-platform exit acceptance.
- Final validation: all 1223 Flutter tests pass; analysis has zero errors/warnings and 67 infos (23 existing + 44 remaining context findings). Structure/67 business-entry gates, 56 Python tests (3 platform-tool skips), dependency locks and formatting pass. Logs: output/sync-window-{targeted,full,analyze}.log. User edits participate in tests; this commit contains only this stage.

## P4/P6/P8: History refresh cancellation and page lifecycle (2026-10-03)

- HistoryPage owns batch progress through StreamIterator. Cancellation or disposal cancels the subscription; completion and failure clean up the subscription and dialog and restore retry. Single refreshes deduplicate by comic identity; batch and single refreshes are mutually exclusive within the page. Late messages require the owning page to remain mounted.
- HistoryManager forwards producer failures and closes the stream in finally. Subscription cancellation reaches the shared throttled runner, which checks before and after the throttle gate and stops scheduling new requests. In-flight requests and existing throttle waits may finish; cancellation does not abort network calls or roll back writes.
- Eight new tests cover success, failure/retry, cancellation, disposal, duplicate actions, late single failures, producer setup failure, and cancellation during work/throttling. Widget tests drain asynchronous cleanup explicitly and access the invisible empty-list sliver for its menu callback.
- Validation: all 1231 Flutter tests passed; analysis has no errors/warnings and 65 infos (23 existing plus 42 context findings). Structure and 67 business-entry checks passed; 56 Python tests ran successfully with 3 platform-tool skips; Git dependencies match. Logs: output/history-refresh-{targeted,full,final-analyze}.log. Existing user changes participate in working-tree tests but are excluded from this commit. Cross-platform and device-performance acceptance remains outstanding.

## P7: Source repository/update error presentation boundaries (2026-10-03)

- SourceFailureCode/SourceFailure give stable reasons for URL/catalog/name validation, missing/duplicate/changed repositories, missing/ambiguous sources and duplicate updates. JSON failures retain the original exception and stack. The update service no longer translates business errors. The error model has no UI/global-configuration dependencies and is enrolled as a business entrypoint.
- SourceCheckFailure preserves the cause and repository/source scope. Pages translate through sourceFailureMessage at presentation time; CLI assembly converts checks to the existing string-array protocol. Import preview catalog errors migrate as well; network and unknown failures retain their types and diagnostics.
- Four new tests cover language changes, original exceptions/stacks, scoped formatting and mixed repository failures without stopping later checks. Existing assertions check specific codes. The first full run found six catalog tests still expecting String; these were migrated before another full run.
- Final full Flutter suite: 1235 passed. Strengthened language assertions then passed all three targeted cases. Analysis: no errors/warnings, 65 infos. Structure/68 business-entry gates passed; 56 Python tests ran successfully with 3 platform-tool skips; Git dependencies match. Logs: output/source-errors-final-full.log, output/source-errors-final-analyze.log, output/source-errors-language.log.
- P7.5 remains incomplete: cancellation/unsupported outcomes, legacy Res adapters and other translated service exceptions still require migration. Repository origin labels and migration default names retain their legacy presentation/persistence behavior. No claim of global error-protocol completion or platform/performance acceptance. Existing user edits are excluded.

## P7: Source-update cancellation is no longer success (2026-10-03)

- Cancellation during repository lookup, script download or before commit now throws SourceFailureCode.cancelled with the original cause and stack. Previously normal return could count cancellation as headless success. CLI retains its existing fields, counts cancellation under errors and continues other sources. Cancellation is not logged as an ordinary network failure.
- The single-update UI adapter suppresses cancellation messages and still closes its dialog in finally. Non-dialog callers receive cancellation. Completed script commits remain successful and are not rolled back. Existing immediate-retry and old-request cleanup ownership behavior remains intact.
- Added direct cancellation scenarios for linked/unlinked sources inside the existing combined Widget test, checking code, original network error, unchanged files and released lock; added one CLI cancellation/continuation/counting test. Ten targeted tests and all 1236 Flutter tests passed. Analysis: no errors/warnings, 65 infos. Structure/68 business entries, 56 Python tests (3 platform-tool skips) and Git dependency checks passed. Logs: output/source-cancel-{targeted,full,analyze}.log.
- Unsupported outcomes, legacy Res adapters and other service errors remain under P7.5. Platform/performance acceptance remains separate. Only this stage is committed; existing user edits are preserved.

## P7: Structured Res failure adapter and source-parser diagnostics (2026-10-03)

- Independent FailureDetails/OperationFailure distinguish failed/cancelled/unsupported and retain message, original cause and stack. SourceFailure implements this contract. Only explicit cancellation types and standard UnsupportedError are classified; message text is not used to infer a kind.
- Res.failure/fromException retain structured diagnostics behind the existing errorMessage/error/success/dataOrNull API. fromErrorRes preserves the failure while converting result types. Legacy const constructors, string errors and the data getter behavior remain unchanged; this is not a whole-repository interface replacement.
- Migrated 31 caught exceptions across eight source capability parsers to fromException, also capturing the dynamic-category stack. Absent optional capabilities remain null. Direct validation strings and other domains remain on the acceptance checklist; not all Res callers are migrated.
- Four new adapter tests cover legacy compatibility, cause/stack forwarding, cancellation and unsupported classification. Real QuickJS lifecycle assertions now verify diagnostics for malformed data and JS exceptions alongside existing text. All 29 targeted and 1240 full Flutter tests passed. Analysis: no errors/warnings, 65 infos. Structure/70 business entries, 56 Python tests (3 platform-tool skips), Git dependencies and formatting passed. Logs: output/res-failure-{targeted,full,final-analyze}.log. Existing user edits participate in working-tree tests but are excluded from the commit.

## P4/P5: Reader-local interaction contract for image retry (2026-10-03)

- ComicImage no longer imports a concrete gesture State or GlobalState. ReaderTapScope exposes only ignoreNextTap to descendants. The gesture listener owns the scope; retries resolve the nearest current owner instead of searching a global registry. Standalone images can retry without a reader.
- ReaderGestureDetectorState now extends ordinary State, removing global registration and its registry key. No GlobalState/AutomaticGlobalState references remain in the reader directory. Concrete scaffold State handles and ReaderImages host coupling remain under P5.
- Two Widget tests cover standalone retry, nearest nested owner, callback replacement and disposal. Strengthened ordering assertions verify suppression before ancestor PointerDown handling. All 1242 Flutter tests and two final targeted tests passed; analysis has no errors/warnings and 65 infos. Structure/70 business entries, 56 Python tests (3 platform-tool skips) and Git dependencies passed. Logs: output/reader-tap-{full,analyze,final-targeted}.log.
- The gesture file contains user edits. Its staged version was generated from HEAD with only this stage's four changes and formatting; user timer/pointer/long-press changes remain in the working tree. Tests cover the whole working tree, not an isolated staged checkout or platform/performance acceptance.

## P5: Content-load orchestration belongs to the reader controller (2026-10-03)

- ReaderController.loadContent owns deduplication, preparation/fetch/mode-preparation phases and success/failure commits. Ownership is checked at each asynchronous boundary; replaced/disposed attempts return ignored without advancing or replacing newer content.
- ReaderImages wires local migration, chapter loading and mode preparation, then presents ready/failed/ignored outcomes. Migration now checks scope cancellation after its wait, preventing stale mounted tasks from restoring old positions or starting new requests. History/content-ready notifications retain their microtask timing.
- Ten new controller tests cover deduplication, loading until preparation ends, retry after each phase fails, and replacement/disposal during each phase. All 19 targeted and 1252 full Flutter tests passed. Analysis has no errors/warnings and 65 infos; structure/70 business entries, 56 Python tests (3 platform-tool skips), Git dependencies and formatting passed. Logs: output/reader-load-{targeted,full,analyze}.log.
- P5 remains incomplete: migration state, viewport binding, preferences and comment assembly still reference ReaderState. Already-started mode probes keep their existing lifecycle ownership; this controller rejects stale content commits without rolling back external effects. Existing user reader changes are preserved and excluded from this commit.

## P5: Viewport attachment ownership and host transfer (2026-10-03)

- ReaderViewportBinding owns the current viewport, identity-based detach, mode-switch clearing and rejection after disposal. ReaderState exposes imageViewController as a read-only getter; ReaderImages removes direct host-field writes and wires the binding callback instead.
- Gallery/continuous didUpdateWidget transfers retained view State from an old attachment callback to a new one, releasing the old host before attaching to the new host. A stale viewport detach cannot clear its successor.
- Two new binding tests plus strengthened standalone tests across seven modes verify retained view identity and old-host release. Automatic-mode tests now explicitly attach viewports. All 19 targeted and 1254 full Flutter tests passed; analysis has no errors/warnings and 65 infos. Structure/70 business entries, 56 Python tests (3 platform-tool skips), Git dependencies and formatting passed. Logs: output/viewport-binding-{targeted,full,final-analyze}.log.
- P5 still requires local-migration ownership and the remaining ReaderImages host inputs/actions. Existing user gesture/auto-reading/scaffold edits participate in working-tree regression but are not changed or included in this commit.

## P5: Separate page-order migration from initial-position restoration (2026-10-03)

- ReaderPageOrderMigration retains an immutable session mapping, shares pending work, caches success and permits retries after synchronous/asynchronous failure. Restoration separately checks cancellation, initial position and current chapter and runs once. Cancellation does not undo persisted migration.
- Retaining the original mapping prevents a cancelled view's retry from matching against already-mutated history. Moving to another chapter does not apply the initial mapping there. ReaderState adapts history/LocalManager; ReaderImages drops direct local-library access and localPageOrderChecked writes.
- Eight new tests cover cancellation/retry mapping, concurrency, both failure modes, mismatched chapter/page or absent history, and pre-cancellation. All 31 targeted and 1262 full Flutter tests passed. After fixing the local-library import entrypoint, 18 automatic-mode/migration tests passed and analysis has no errors/warnings with 65 infos. Structure/71 business entries, 56 Python tests (3 platform-tool skips), Git dependencies and formatting passed. Logs: output/page-order-session-{targeted,full,final-targeted,final-analyze}.log.
- P5 still needs remaining ReaderImages host inputs/UI actions and reader-shell contracts. Session-level tests do not replace storage migration or platform/performance acceptance. Existing user changes are excluded.

## P5: Standalone content view and explicit host composition (2026-10-03)

- ReaderImages no longer holds/looks up ReaderState or reads preferences, source services or cache. It consumes ReaderController, explicit load/lifecycle callbacks and content-snapshot builders, owning only the view's load attempt. Controller replacement cancels the old attempt and rejects late notifications.
- Stateless ReaderImagesHost explicitly receives ReaderState and composes comments, mode snapshots, image reads and shell actions. ReaderController retains load deduplication/commits. Retry now reports loading and checks attempt identity, preventing late verification callbacks from retrying disposed/replaced views. Synchronous position commit, settlement update and microtask-ready ordering is preserved.
- Eight new standalone Widget cases cover loading without a reader page, repeated rebuilds, error retry, disposal during three phases, controller transfer and late retry after disposal/replacement. The 25-case mode/seven-mode auto-reading/slider suite passed; final full Flutter suite passed all 1270 tests. Analysis: no errors/warnings, 65 infos. Structure/71 business entries, 56 Python tests (3 platform-tool skips) and Git dependencies passed. Logs: output/reader-content-view-{final-targeted,retry,final-full,final-analyze}.log.
- P5.3/P5.5 implementation evidence is updated subject to overall acceptance. ReaderImagesHost intentionally retains explicit page-composition dependencies; this does not claim the entire shell/all State is decoupled. P5.6 and native platform/performance acceptance remain. User edits participate in working-tree tests but are excluded from this commit.

## P5: Swipe collection subscription and gesture host port (2026-10-03)

- ReaderGesturePort narrows the shell dependency to tap suppression and drag subscriptions. The gesture host binds immediately on mount and detaches by identity on disposal, without clearing a replacement host. Removed the 200 ms delayed registration.
- ImageFavoriteSwipeBinding owns one listener, deduplicates repeated settings updates, and releases/reset state on host transfer, disabling and disposal. It retains cross-axis collection with absolute distance strictly greater than 150; captured callbacks cannot collect after disabling/disposal.
- Added five tests for both reading axes, threshold, duplicate subscriptions, transfer and disabling/disposal. Full Flutter suite: 1275 passing; analyzer: zero errors/warnings, 65 infos. Structure/71 business entries, Python 56 tests (three platform-tool skips), and Git dependency checks passed. Logs: output/swipe-binding-{targeted,full,clean-analyze}.log. The first analysis scanned temporary staging Dart files and found a redundant test import; cleanup and rerun passed.
- P5.6 remains partial; menus, sidebars and other shell responsibilities still need review. Gesture/scaffold staging was generated from HEAD with only this stage applied; user edits remain in the working tree. Tests cover the working tree, not an isolated commit or five-platform/performance acceptance.

## P5: Image picking rules and content identity (2026-10-03)

- ReaderImagePicker extracts single-image range checks, multi-image hit testing and asynchronous selection generations from the shell. ReaderImagePickingViewport exposes only source-image range and positional hit testing; gallery/continuous viewports inherit it through the existing viewport protocol, removing duplicate declarations. The picker is enrolled as a business entry point.
- ReaderImagePick retains viewport, immutable image-list and chapter identity. Collection and export validate the current content after awaiting selection, including fast single-image selection followed by chapter/content/viewport changes. This prevents old indices from being applied to a new chapter. Empty content no longer opens selection UI; the existing overlay still owns UI and disposal.
- Added 12 tests covering valid/invalid single ranges, empty content, multi-image hits, unknown/null hits, cancellation, four identity changes, replacement, disposal, consumer validation after immediate completion, and retry after failure. Selection/overlay/export targeted suite: 19 passing; final selection/seven-mode viewport suite: 19 passing; full Flutter suite: 1287 passing. Analyzer: zero errors/warnings, 65 existing infos. Structure/72 business entries, Python 56 tests (three platform-tool skips), and Git dependency gates passed. Logs: output/image-picker-{targeted,full,final-targeted,final-analyze}.log.
- P5.6 remains partial: menus, sidebars and remaining shell responsibilities still need review. Shell staging was generated from HEAD with only this stage applied, preserving user menu/automatic-reading edits. Tests cover the working tree, not isolated-commit, platform or performance acceptance.

## P5: Reader sidebar requests and interaction lifecycle (2026-10-03)

- ReaderSidebarBinding owns one pending/open sidebar, its route handle and interaction release callback. Duplicate requests cannot stack pauses or routes. Host conditions are checked before acquisition and again after the frame; an explicit visual update schedules idle-frame callbacks.
- Chapters, settings and chapter comments now share the binding, preserving widths of 400/400/500. Each shell uses a separate pause reason and releases the original gesture host. Closing, opening failure and disposal release once without clearing other automatic-reading pause reasons.
- Disposal invalidates pending requests immediately, then removes only its own active route and releases interaction in a microtask after tree finalization. Unrelated later routes remain intact. An unmounted reader State is not used to access its automatic-reading controller. The binding is enrolled as a UI boundary.
- Added 10 widget regressions for duplicates, changed eligibility, cancellation, surviving and disposed navigators, route lookup failures/retry, route defaults, independent pauses and acquisition/release failures. Initial tests exposed missing frame scheduling while idle; ensureVisualUpdate fixed it. Full Flutter suite: 1296 passing; the final targeted suite with the additional whole-navigator disposal case: 10 passing. Analyzer: zero errors/warnings, 65 existing infos. Structure/72 business entries, Python 56 tests (three platform-tool skips), and Git dependency gates passed. Logs: output/sidebar-binding-{full,final-targeted,final-analyze}.log.
- P5.6 remains incomplete: menu assembly and remaining shell responsibilities still need review; sidebar tests do not replace platform/performance acceptance. Shell staging applies only this stage to HEAD and preserves existing user menu-lock edits in the working tree. Tests cover the working tree.

## P5: Bottom-action presentation separated from shell assembly (2026-10-03)

- bottom_actions.dart renders collection, fullscreen, rotation, brightness, automatic reading, chapters, save and share actions from explicit state/callbacks without ReaderState, App or settings. Optional callbacks express platform/chapter capabilities. The host interprets automatic-reading behavior and tooltip; ReaderAutomaticReadingAction carries only presentation state and the action.
- ReaderBottomBar previously estimated the page badge with a fixed 120-pixel allowance, overflowing in landscape at 3.2x text scaling. It now measures scaled text and action width, using the existing actions-only layout when the badge cannot fit its height/remaining width. Button order, icons, theme colors and callbacks are preserved.
- Added nine widget tests covering 375x667, 667x375 and 1024x768 in light/dark themes with 3.2x text and reduced motion. Assertions cover at least 48x48 targets, bottom safe area, capability visibility, one dispatch per action, orientation/selected state, tooltip semantics and Tab/Enter activation. Initial tests exposed the landscape overflow, now fixed; semantics assertions inspect the actual subtree and explicitly release the test handle.
- Full Flutter suite: 1306 passing; final targeted suite with strengthened target/safe-area assertions: nine passing. Analyzer: zero errors/warnings, 65 existing infos. Structure/72 business entries, Python 56 tests (three platform-tool skips), and Git dependency gates passed. Logs: output/bottom-actions-{full,final-targeted,analyze}.log. The new presentation component is enrolled as a UI boundary.
- Remaining P5.6 menu assembly and shell responsibilities still need review. Flutter accessibility guidance from ui-ux-pro-max informed component checks; widget tests do not replace actual TalkBack/VoiceOver, platform or performance acceptance. Shell staging applies only this stage to HEAD, leaving user menu-lock/manual-pause behavior in the working tree where it participates in regression tests.

## P1: Direct dependency and tracked artifact usage audit (2026-10-03)

- Added bilingual dependency_artifact_audit covering 881 tracked paths at 9b06917, 51 dependency declarations, 27 maintenance/packaging tools and 14 nonempty byte-identical groups. No tracked temporary logs/caches/archives were found; platform resources and project metadata remain. windows/build_arm64.py has no tracked caller and remains an explicit manual-entry investigation candidate.
- Removed dev package flutter_to_arch and its exclusive transitive io: CI already uses the project Python Arch packager. The same-named top-level configuration is retained and documented as Python input. sqlite3_flutter_libs, flutter_lints and flutter_rust_bridge remain for native libraries, configuration inclusion and rhttp compatibility. All retained versions, sources and checksums are unchanged.
- The first pub remove inherited a mirror setting and introduced unrelated upgrades/source changes; all were reverted. Starting from the original lockfile with only two packages removed, offline pub get with PUB_HOSTED_URL=https://pub.dev succeeded. The final lockfile only deletes 16 lines.
- Added a Python Arch --prepare-only integration regression using temporary paths to verify archive contents, desktop entry, system dependencies and Dockerfile, forbidding external commands and leaving user build directories untouched. Python: 57 passing (three platform-tool skips); Flutter: 1306 passing; analyzer: zero errors/warnings, 65 existing infos. Structure/72 business entries and Git dependency gates passed. Logs: output/dependency-{arch-locked-get,usage-full,usage-analyze}.log.
- P1.4/P1.5 usage evidence is recorded; P1.3 public-symbol/dynamic-entry/test/compatibility candidate classification remains incomplete. Arch preparation is not Linux makepkg/installation acceptance. Existing user edits are excluded from the commit.

## P1: Public-symbol candidate inventory and unused extensions (2026-10-03)

- Added an isolated tool/code_audit maintenance package using analyzer 9.0.0 ASTs over tracked production/test files, without changing app dependencies. Self-checks cover declaration kinds, local/private-name exclusions, annotations, exact strings and duplicate visits. CI prepares locked tool dependencies and runs its self-check/analysis before repository analysis.
- All 378 Dart files are potentially reachable from main.dart. Of 6071 public-name declarations, 341 low-reference candidates are classified individually in JSON: 262 framework/protocol/implicit-extension, 42 with test evidence, one runtime entry and 36 investigation items. Bilingual documentation explains same-name collisions, dynamic dispatch and the lack of resolved call analysis; an empty candidate result would not prove no dead code.
- Source/test/assets/API/example/patch searches confirmed no callers for 13 list/string/translation/widget-style extension members. Removed those and the private _nums helper used only by nums, retaining other members without replacement implementations. widget_utils.dart was formatted to satisfy the changed-file gate.
- Tool self-check and standalone analysis passed. Flutter: 1306 passing; analyzer: zero errors/warnings, 65 existing infos. Structure/72 business entries, Python 57 tests (three platform-tool skips) and application Git dependency gates passed. Logs: output/public-symbol-{full,analyze}.log. App pubspec/lock remain unchanged; tool lockfile uses pub.dev.
- The P1.3 inventory is delivered, but 36 investigation symbols, legacy import/export protocols, test hooks and global lifetimes still need follow-up. Overall optimization remains incomplete. Existing user working-tree edits are excluded from staging.

## P1/P8: Retire legacy batch archive executors (2026-10-03)

- Production, test, script and JS/API reference checks found no callers for ComicExporter, ComicImporter or their ImportResult. Removed those dormant executors. Current CBZ/PDF/EPUB and application backup flows remain separate; historical .venera-comics is not described as an active import feature.
- Preserved the existing ComicExportInfo/ComicExportMetadata codec in dependency-free legacy_comic_metadata.dart, removed the executor-only factory and retained all existing tests with a direct import. The production barrel no longer exposes it. Registered retired paths and the 73rd business entry.
- All 38 targeted and 1306 Flutter tests passed; analyzer: zero errors/warnings, 65 existing infos. Structure, 57 Python tests (three platform-tool skips) and Git dependency checks passed. Logs: output/legacy-codec-{targeted,full,analyze}.log. Tests include existing user workspace changes.
- Added bilingual legacy_comic_archive_audit and three resolutions to the historical candidate snapshot; 33 investigations remain. Updated P1.3/P8.1 evidence without claiming P6 atomicity, P7 protocols or platform acceptance complete. Existing user changes are excluded from this commit.

## P7: Repeated workflow mechanisms and domain differences (2026-10-03)

- Added bilingual repeated_workflow_matrix covering scheduling, progress, cancellation, ownership and commit boundaries for source updates, images, archive download/export, application sync and document import. Recorded actual consumers and limits of RequestScope, batch throttling, SQL transactions, directory recovery and document sessions.
- Distinguished cancellation of waiting from termination of underlying work, extraction/commit draining, shared-image subscriber ownership and per-source fairness. No universal task framework introduced.
- P7.3 comparison delivered; P7.4 retry/progress review, P7.5 error migration and P4/P6 lifecycle/atomicity remain open. Documentation only: checked implementations/test paths and diff, without repeating full tests. Prior 1306 passing tests do not replace outstanding acceptance. User edits excluded.

## P6: Canonical path protection for local deletion (2026-10-03)

- Added asynchronous identity checks to local_deletion_paths: retain lexical overlap protection, then compare canonical candidates, references and library root. Missing suffixes resolve through existing ancestors; failed resolution returns no cleanup list. Deletion keeps original registered paths rather than converting a link deletion into target-directory deletion.
- LocalManager adapts native identity and SAF provider paths (the plugin does not implement resolveSymbolicLinks). Retained chapters of the same book now participate in protection after excluding the book root, closing the chapter-alias gap.
- Six new regressions: real Windows junctions for registered aliases, retained chapter aliases, aliased descendants and library root, plus missing suffixes and failed identity resolution. All 20 targeted tests passed. Initial mklink fixture failures were fixed by normalizing Windows separators; junction tests were not skipped.
- This stage does not solve atomic deletion across local/history/favorites databases and files. Existing operations still mutate records before directory cleanup, and external processes can replace links after checking. SAF device behavior, non-Windows links and all direct writers remain subject to acceptance; P6.3/P6.7 stay partial.
- Full Flutter: 1312 passed; analyzer: zero errors/warnings, 65 existing infos. Structure/73 business entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-identity-{targeted,full,analyze}.log. Tests cover the current workspace; user edits are excluded from the commit.

## P6: Propagate cross-folder favorite deletion failures (2026-10-03)

- Removed swallowed errors from batchDeleteComicsInAllFolders. Repository transaction failures reach callers; caches, covers and notifications update only after successful commit. The local batch-delete page already catches errors, so failure no longer reports success or proceeds to file cleanup.
- Single local-comic deletion now removes favorites with one cross-folder transaction instead of separate transactions per folder. A later-folder failure rolls back the entire favorite group. Existing history write ordering is retained.
- Updated the existing injected-failure assertion and added two cross-manager regressions: single deletion retains the local record/files and supports retry after favorite rollback; batch failure propagates and retains files. All 28 targeted tests passed. The first attempt counted an outstanding initialization cache refresh; the fixture now waits for that refresh before tracking notifications.
- Cross-database/filesystem atomicity remains incomplete: batch deletion commits local records first; single deletion commits history first. Subsequent favorite failures do not roll back those commits. This establishes observable failure boundaries, not whole-operation rollback. P6.7 remains partial pending unified commit/recovery and retry coverage.
- Full Flutter: 1314 passed; analyzer: zero errors/warnings, 65 existing infos. Structure/73 business entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-failure-{targeted,full,analyze}.log. Existing user workspace changes participate in tests but are excluded from this commit.

## P6: One transaction for local, favorite and history deletion (2026-10-03)

- Added local_deletion_storage using the existing local connection with temporary favorite/history attachments and an outer BEGIN IMMEDIATE transaction. Repository failures roll back all three databases, including local page-migration records. Attachments detach in finally; retries verify release and rollback boundaries.
- Single/batch associated deletion runs through the history queue's synchronous external-commit entry. Accepted progress writes finish first; the transaction does not yield. After commit, history cache refresh precedes favorite counts/cover cleanup/notifications; local notification and directory cleanup follow. Closed/path-change checks remain; disabling associated deletion uses only the local repository.
- Favorite deletion accepts an explicitly quoted schema. Tests cover a comics folder and a quoted folder name to prevent attached-table collisions. refreshDeletedFavorites publishes real external commits; removed the now-unused production batchDeleteComicsInAllFolders method and adapted manager tests to external-commit cache publication and failure behavior.
- Strengthened both existing cross-manager tests with full record rollback and batch retry. Added four regressions for local/history failures, queued progress/committed visibility and attached table identifiers. All 36 targeted tests passed before the final identifier case; full Flutter: 1318 passed. Final analyzer: zero errors/warnings, 65 existing infos. Structure/74 business entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-transaction-{targeted,full,final-analyze}.log. Added braces to two new branches after initial lint findings.
- P6.7 remains partial despite verified three-database exception rollback: filesystem cleanup follows DB commit; cleanup failure/process termination recovery, post-commit cache publication failure, external link replacement and unguarded writers remain. Connections use DELETE journaling; ordinary exception tests do not establish power-loss/crash recovery. User workspace edits participate in tests but are excluded from this commit.

## P6: Preflight deletion paths before database commit (2026-10-03)

- Single, batch and chapter deletion validate candidate paths and proposed retained references before mutating databases. LocalRepository can exclude multiple id/type pairs while reading only reference columns, without decoding unrelated display metadata. Chapter preflight uses proposed retained chapters; SQL still operates on current rows.
- Post-commit cleanup reuses the same resolver and checks current references again. Successful preflight is not unconditional permission for later deletion. Unregister-only operations do not require paths to resolve.
- Added three real broken-junction regressions for single/batch/chapter deletion: resolution failure leaves records/chapters, notifications and files untouched; unregistering the broken reference without disk cleanup allows retry. All 26 targeted tests passed.
- Preflight cannot predict permission changes, disk errors or external link replacement. Filesystem cleanup still follows DB commit. Durable cleanup intent/interruption recovery, post-commit publication failure and coordination of all direct writers remain; P6.7 stays partial.
- Full Flutter: 1321 passed; final repository tests: four passed after strengthening multiple/duplicate/missing identities and same-id different-source assertions. Analyzer: zero errors/warnings, 65 existing infos. Structure/74 business entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-preflight-{targeted,full,final-repository,analyze}.log. User edits excluded.

## P6: Durable quarantine and deletion recovery (2026-10-03)

- local_deletion_journal persists sibling quarantine paths before moving and commits its marker with record deletion. Failure restores files; committed cleanup deletes only quarantine and preserves new files at the original path. Conflicts, missing pairs and malformed journals retain evidence and fail without guessing/overwriting.
- Integrated single/batch/chapter flows and recovery before initialization/exclusive operations/migration. Record snapshots are checked inside the transaction against changes during staging. Removed direct cleanup/isolate wrapper; SAF uses provider rename/asynchronous deletion.
- Added seven journal fault/reopen tests and two manager-recreation tests. Original targeted 22, final recovery 20 and full Flutter 1330 passed. Analyzer zero errors/warnings, 65 existing infos; structure/75 entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Fixed two initial brace lint findings.
- See local_deletion_recovery.en.md for states, logs and remaining acceptance. Reopening does not replace termination/power-loss or SAF device tests; external writers, publication outcomes and conflict repair remain. P6.7 stays partial. User workspace changes excluded from commit.

## P6: Deletion recovery after real process termination (2026-10-03)

- Added a separate Dart VM probe that synchronously reports PID and blocks after staging, during transaction and after commit. Parent validates PID, kills that process and awaits exit; child finally cleanup cannot establish the result. Uses production journal/connection/transaction utilities with three minimal records databases, not full-application schema/lifecycle acceptance.
- Verified uncommitted three-database rollback/file restoration, committed quarantine cleanup, original-path replacement protection and repeat recovery. Initial launcher/VM PID mismatch was fixed by invoking the VM directly; killing a launcher was not accepted as evidence.
- Three targeted and 1333 full Flutter tests passed. Final analyzer: zero errors/warnings, 65 existing infos; structure/75 entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-crash-{targeted,full,final-analyze}.log. Added braces to the previous stage's late restart-test branch.
- Three deterministic Windows windows now have evidence; full-app random termination, SAF, other platforms and power loss remain open. P6.7 stays partial; user changes excluded.

## P6: Synchronous writer ownership and page-migration reservation (2026-10-03)

- Added LocalComicStorageGuard.write with instance-private Zone owner tokens. Exclusive operations reject unrelated writes; accepted owners can drain during exit; expired owner callbacks cannot write. LocalManager.add/remove use this boundary. Recovery scanning can register within its own exclusive scope without waiting on itself.
- Legacy page conversion holds a storage reservation through enumeration, marker and history writes; non-local histories remain no-op. Removed the unused chapter argument/update branch from isDownloaded and the production-unused removeComic forwarder. Marked its historical test-evidence candidate resolved without changing the 33 investigation count.
- Six new owner/manager/migration-wait tests. Full 1338 passed before the final migration-wait case; final targeted 20 passed. Final analyzer zero errors/warnings, 65 existing infos; structure/75 entries, 57 Python tests (three platform-tool skips), Git dependency/format checks passed. Logs: output/local-write-owner-{targeted,final-targeted,full,final-analyze}.log.
- See local_storage_writer_audit.en.md. Download queues retain separate ownership; external SQL, reader file lifetimes and platform shutdown still need acceptance. P6/P4 remain incomplete. User edits excluded.

## P1/P8: Close original symbol investigations (2026-10-03)

- Three legacy archive candidates were resolved earlier; removed the remaining 33 and their orphan dependencies after checking production, tests, JS/API, assets and platform references. Active protocol and serialization fields remain.
- Removed the test-only batchDeleteHistories forwarder left after the three-database migration; its queue test now exercises production importStorage and repository batch deletion.
- Final rescan: 379 production files, 221 test files, 6036 public-name declarations, 304 candidates, all matching historical classified entries. Name counts are not a resolved call graph or proof of zero dead code.
- Final full Flutter suite: 1339 passed; analysis: zero errors/warnings, 63 infos. Structure/75 entries, Python 57 (3 skips), Git dependency checks and audit-tool self-check/analysis passed. Logs: output/investigation-cleanup-{final-full,final-analyze}.log.
- Bilingual investigation_resolution and historical candidate resolutions updated. P8 remains partial. Existing user changes participated in workspace tests but are excluded from the commit.

## P1: Unify Windows manual packaging (2026-10-03)

- windows/build.py accepts --arch x64/arm64 and defaults to x64, preserving CI usage. build_arm64.py remains a manual command adapter; build, ZIP, translation and installer logic are shared. Artifact names and architecture-specific ISS templates remain unchanged.
- Commands check exit codes and run at the repository root. Installer templates are restored byte-for-byte; stale installers are removed before compilation. Recursive cleanup checks resolved containment within build/windows, and version parsing rejects path injection.
- Six new tests cover full ZIP contents/architecture isolation, stopping after build failure, template restoration, cleanup boundaries, versions and command cwd. Python: 63 passed with 3 existing skips; structure and architecture checks pass. No Dart changes or repeated Flutter suite in this stage.
- Commands: python windows/build.py for x64; python windows/build.py --arch arm64 or python windows/build_arm64.py for ARM64. Real ARM64 compilation, Inno installation and platform release remain unverified; P0/P8 remain open. User changes excluded.

## P8/P7: Favorite-panel async ownership and shared mutation flow (2026-10-03)

- NetworkFavoriteSection accepts FavoriteData. Single/multiple folders share request, busy-state, exception conversion and post-commit presentation. Duplicate taps submit once; remote success invalidates network cache even after panel disposal, while callbacks/navigation require a mounted owner.
- Folder exceptions now offer retry instead of remaining busy or dereferencing null folders. Local folder creation checks mounting on completion. Source protocol, persisted data and favorite layout are unchanged.
- Five new behavioral tests cover both mutation modes, duplicate calls, late success/cache invalidation, retry after exceptions, and folder retry/late exceptions after disposal. Focused 5 and full Flutter 1344 tests passed; analysis: zero errors/warnings, 56 infos. Structure, architecture and Git dependency gates passed. Logs: output/favorite-lifecycle-{targeted,full,analyze}.log.
- Seven async-context findings resolved here, 35 remain repository-wide; P8.2 stays partial. Existing user changes participated in workspace validation but are excluded from the commit.

## P8/P7: Network-favorites requests and dialog lifecycle (2026-10-03)

- Folder loading moved from build to initState/explicit reload, preventing rebuild duplication and converting exceptions into retryable failures without updating disposed State.
- Comic/folder deletion shares confirmNetworkFavoriteDeletion with operations injected from the current FavoriteData, removing global source and root-context lookups. Busy requests reject duplicate taps; exceptions reset controls. Success clears cache and refreshes live owners without presenting or popping from dismissed dialogs.
- Folder creation captures the parent callback, refreshes a live parent after late success and permits retry after failure; its text controller is disposed. Comic removal inside a folder now sends the actual folderID, covered through the production menu path.
- Final focused 6 and full Flutter 1350 tests passed. Final analysis: zero errors/warnings, 47 infos; structure, architecture and Git dependency gates passed. An unnecessary test null assertion found in the first analysis was removed, followed by final analysis and focused tests. Logs: output/network-favorites-{full,final-targeted,final-analyze}.log.
- Nine async-context diagnostics resolved here; 26 remain repository-wide. Severity remains info and P8 stays partial. Existing user changes participated in workspace tests but are excluded from the commit.

## P8/P7: Application settings task presentation and cleanup (2026-10-03)

- SettingsTaskPresenter owns per-page duplicate-trigger control, progress routes and finally cleanup, replacing four manual close paths for migration/cache/export/import. Returned failures and exceptions do not publish success. Accepted tasks finish cleanup after page disposal; UI presentation/refresh requires the calling context to remain mounted. Import retains temporary-file cleanup and application rebuild ownership.
- Directory selection checks page lifetime on return. Authorization capability checks use request generations and exception fallback; persisted fallback does not depend on page lifetime, while presentation does. Sync configuration checks its actual builder context. This UI helper is not a business entry and does not replace storage locking, cancellation or rollback.
- Five tests cover success/failure cleanup, reentry, disposal and returned operation errors. Initial focused assertions used circular progress instead of the actual linear widget and were corrected. The initial full run exposed a nullable captured directory argument; the explicit assertion after the null check was restored. Final full suite: 1355 passed; analysis: zero errors/warnings, 38 infos. Structure, architecture and Git dependency gates passed. Logs: output/settings-task-{targeted,full,final-full,final-analyze}.log; full preserves the failed run.
- Nine application-settings context findings resolved, 17 remain; P8.2 stays partial. Real biometric, picker and migration platform evidence is still missing; these tests do not prove native workflows. Existing user changes participated in workspace tests but are excluded from this commit.

## P8: Local favorite cleanup and summary frame callbacks (2026-10-03)

- Invalid-favorite cleanup reuses SettingsTaskPresenter: duplicate triggers are guarded, failures close progress without publishing counts, and success is presented only to a live page. Repository deletion behavior is unchanged.
- Image-favorite chart switching uses post-layout callbacks instead of a fixed 20ms delay, checking mounting, latest selection generation, scroll host and controller attachment. Summary refresh also rejects stale request generations.
- Three real database/widget tests cover missing scroll hosts, disposal after selection and rapid switching before scrolling to the latest layout. Combined with task-presentation tests, 8 focused tests passed. Initial fixtures omitted App path initialization and were corrected. Final full Flutter suite: 1358 passed; analysis: zero errors/warnings, 36 infos; structure, architecture and Git dependency gates passed. Logs: output/favorites-summary-{targeted,full,analyze}.log.
- Two context findings resolved, 15 remain; P8.2 stays incomplete. Small fixtures do not cover all >100-item background-isolate races or performance, and overall platform/performance validation remains open. Existing user changes participated in tests but are excluded from the commit.

## P8/P4: Comment-link routing and recognizer ownership (2026-10-03)

- openCommentLink binds the original context, route and root navigator. After an app link opens, only the original root-owned route is removed, avoiding a late maybePop that closes the new page. App-link processing receives an active predicate; disposed/stale owners do not launch external fallback, and exceptions are logged. Production retains existing app-link and URL-launch implementations behind explicit adapters.
- RichCommentContent owns every TapGestureRecognizer, releasing/rebuilding on text or dependency changes and releasing all on disposal. Rendering clears old spans/images; text replacement no longer displays stale content, and old text callbacks do not initiate work.
- Five widget tests pass: content replacement, original-route removal while preserving the new page, late failure/unhandled results after disposal, and live external fallback. Full Flutter: 1363 passed; analysis: zero errors/warnings, 35 infos. Structure, architecture and Git dependency gates passed. Logs: output/rich-comment-{targeted,full,analyze}.log.
- One context finding resolved, 14 remain. Detail loading and other actions remain on the original backlog; this does not complete the detail domain. System browser/link platform validation remains open. Existing user changes excluded.

## P8/P4: Detail like/rating submission lifecycle (2026-10-03)

- Like busy state binds to the current comic identity and deduplicates same-comic requests. Exceptions retain original error information and release busy state. Results validate mounted/current data ownership before mutation; an old comic cannot overwrite the new one. ComicPage.update refreshes only mounted State.
- Rating UI moved to rating_dialog.dart with a submission closure capturing the current source/comic, without root-context lookup. Initial submission now matches the displayed one star instead of zero. Errors permit retry, duplicate taps submit once, and late completion after dismissal neither updates State nor closes a replacement route.
- Four tests cover like failure/reentry/identity replacement and rating defaults/retry/late success/failure. Focused 4 and full Flutter 1367 tests passed; final analysis: zero errors/warnings, 31 infos. Structure, architecture and Git dependency gates passed. An unused aggregate import left by extraction was found on first analysis and removed before final analysis. Logs: output/reaction-lifecycle-{targeted,full,final-analyze}.log.
- Four context findings resolved, 10 remain; three in actions download paths remain. This does not prove underlying source-request cancellation or real-device networking; P4/P7/P8 remain open. Existing user changes excluded.

## P8/P5: Separate detail download selection from enqueueing (2026-10-03)

- ArchiveDownloadDialog receives fixed downloader/comicId inputs and returns only normal download or a validated URL. It neither reads current detail State nor creates download tasks. List/link operations own their busy state, deduplicate submissions and ignore presentation/navigation after disposal.
- Detail actions capture the original comic, source and context. Normal/archive and chapter selections validate mounted comic identity and existing downloads before enqueueing. One selection flow may open at a time, and exceptions release the guard. Chapter IDs/titles come from the captured comic, avoiding data from a replacement page.
- Four new dialog tests plus existing archive tests: 7 passed; full Flutter: 1371 passed. Final analysis: zero errors/warnings, 28 infos. Structure, architecture and Git dependency gates passed. Three imports and one braces lint left by extraction were found on initial analysis and removed. Logs: output/download-dialog-{targeted,full,final-analyze}.log.
- Three actions context findings resolved, 7 remain. Real source downloads, reconnect/resume and full queue lifecycle are not claimed verified; P6/P7/P8 remain tracked. Existing user changes excluded.

## P8/P4: Local favorite creation and file-import dialog (2026-10-03)

- CreateFavoriteFolderDialog receives validation, creation, selection/read and JSON commit callbacks without global manager access; newFolder remains production composition. State owns/disposes its text controller and preserves existing name-validation rules.
- File import disables creation/duplicate import, presents retryable picker/read/parse errors and preserves drafts when selection is cancelled. Reads may finish after dismissal but cannot commit JSON or operate a replacement page. Underlying read cancellation is not claimed.
- Four widget tests cover late success/error after dismissal, retry after read/parse failures, validation and cancelled selection. Focused 4 and full Flutter 1375 tests passed; analysis: zero errors/warnings, 26 infos. Structure, architecture and Git dependency gates passed. Logs: output/create-favorite-{targeted,full,analyze}.log.
- Two context findings resolved, 5 remain. Network batch favorite import prefetch, close callbacks and post-cancellation commit semantics remain incomplete under P6/P7/P8. Existing user changes excluded.

## P6/P7/P8: Separate network-favorite collection and atomic commit (2026-10-03)

- network_favorite_import extracts RequestScope-controlled prefetch/paging with three-attempt retries, metadata/cursor validation and deduplication. Oldest-first starting pages cannot be negative. Route exit cancels waiting without stale StateSetter/close closures.
- Complete collection enters one transaction checking linkage and writing folders/linkage/all records, with rollback on failure. Cancellation or collection failure no longer imports partial results. Manager caches/notifications publish only after commit; publication-failure semantics remain open. Enrolled business entry number 76.
- Focused 10 passed. The first exit-window test timed out waiting for a perpetual progress animation; it now waits only for route entry before testing immediate cancellation. Full 1385 passed; empty-name validation/assertion added afterward, final focused 10 passed. Final analysis: zero errors/warnings, 25 infos. Structure/architecture, Python 63 (3 skips) and Git dependency gates passed. Logs: output/network-import-{full,final-targeted,final-analyze}.log.
- Protocol, behavior changes, ordering and remaining work are in network_favorite_import.en.md. The last favorite_actions context finding is resolved; 4 remain repository-wide. P6/P7/P8 remain partial and existing user changes are excluded.

## P8/P4: Local detail route replacement and debug presentation (2026-10-03)

- replaceWithRootPage captures current route/root navigator, pushes the destination and removes only the original route. Covered/disposed pages cannot redirect. Nested navigators retain their sole home route; no global main-navigator pop targets an unknown page.
- Delayed local-detail navigation captures its context and checks mounting/request cancellation. Reader ID and session callbacks are captured from the original host. The detail-owned scroll controller is disposed. Debug source-reload errors use only the current mounted nullable root context.
- Three focused root/nested/stale-route tests and full Flutter 1388 tests passed. Initial analysis required checking the actual closure context; explicit capture resolved it. Final analysis: zero errors/warnings, 23 infos. Structure, architecture and Git dependency gates passed. Logs: output/local-redirect-{targeted,full,final-analyze}.log.
- Two context findings remain in the reader gesture file containing user edits; rule severity is unchanged and P4/P8 remain incomplete. User changes excluded.

## P5/P8: reader image action lifecycle and async context enforcement (2026-10-03)

- Copy/save share useReaderImage. Missing viewports do not start work; completed reads require a mounted owner and unchanged viewport, image list and chapter. Missing-image/error presentation is guarded; both reading and platform failures are handled. Already started platform operations may finish; this does not cancel OS save/clipboard effects.
- Six focused tests cover inactive owners, late bytes/misses, read failures, platform failures and awaiting completion. All 1394 Windows Flutter tests pass. Analysis has zero errors/warnings and 21 infos; use_build_context_synchronously has zero findings and is enforced as warning. Structure/architecture (77 business entries), Git dependencies, formatting and 63 Python tests (3 existing skips) pass. Logs: output/gesture-image-{targeted,full,analyze,python}.log.
- gesture.dart and CHANGELOG were staged selectively, preserving user edits. P5/P8 and the overall plan remain incomplete: the other 21 infos, reader shell ownership, native behavior, performance and remaining acceptance items still require work.

## P6/P8: network-favorite committed results and publication recovery (2026-10-03)

- importNetworkFavorites commits the transaction and returns a folder, immutable id/type snapshot and count. publishNetworkFavoriteImport separately refreshes caches/tracking/views. A tracking observer failure does not suppress ordinary view notifications; refresh retries neither collect nor write SQL.
- The dialog records success before publishing. Publication errors appear as refresh errors with Finished and the committed count retained, plus a Refresh retry. Actual commit failure does not publish or offer refresh, and stops the progress animation.
- Five new regressions cover real SQLite commit with repeated publication failure/retry, no publication on commit failure, immutable identities, manager observer failure with ordinary notifications, and publication recovery after database close/reopen. Initial focused 40 passed; after adding reopen coverage, all 1399 Windows Flutter tests passed. Final analysis: zero errors/warnings, 21 infos; structure, architecture, Git dependencies and formatting passed. Logs: output/network-publication-{targeted,full,final-analyze}.log.
- Publication is not cross-process atomic with SQL and notifications have at-least-once semantics. Local JSON import and other publication boundaries, native exit, real-source protocols and performance remain pending. Existing user changes were excluded from this commit.
