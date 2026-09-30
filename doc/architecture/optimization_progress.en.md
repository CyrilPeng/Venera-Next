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
