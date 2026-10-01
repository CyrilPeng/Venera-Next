# Architecture Optimization Execution Record

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
