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
