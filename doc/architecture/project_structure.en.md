# Project Structure

Chinese version: [project_structure.zh.md](project_structure.zh.md)

This document is the English companion for the repository structure rules. The Chinese document is the default maintenance entry and contains the full boundary checklist used during structure refactors.

## General Principles

- `app_shell/` contains app shell entry points, such as authentication, home page composition, and the main navigation shell.
- `app_runtime/` contains runtime assembly, such as startup initialization, update checks, debug reload, and headless command entry points.
- Business code should be grouped by feature domain under `features/<domain>/`.
- Do not add new source files under `pages/`; app-level entry points belong in `app_shell/`, and business pages belong in the corresponding feature domain.
- `foundation/` contains cross-domain application foundations, including app state, initialization protocols, async queues, Dart extensions, constants, logging, localization, file system helpers, image processing, image provider bases, reading-history metadata contracts, platform channels, and shared data infrastructure.
- `components/` contains reusable UI components. Components that only serve one business domain should live inside that feature domain.
- `network/` contains general network, cache, request, and file transfer infrastructure. `network/webdav.dart` owns shared WebDAV endpoints, authentication, client creation, and remote path rules. Business-specific download tasks and API wrappers should remain in their owning feature domain.

## Feature Domains

`lib/features` is the main home for business code. Current domains include:

- `comic_source/`: comic source models, parsing, categories, home summaries, favorites mapping, tag translation, and source translation.
- `comic_storage/`: archive metadata, image file rules, and local filesystem layout detection shared by local directories, CBZ, and WebDAV.
- `comic_widgets/`: cross-domain comic display widgets such as cards, lists, and rating controls.
- `comic_details/`: comic detail page and its chapters, comments, favorites, cover, and thumbnail modules.
- `discovery/`: explore, category, category comic list, and ranking pages.
- `favorites/`: local favorites, network favorites, favorite folders, and favorite actions.
- `follow_updates/`: follow update state, update checks, and the follow-updates page.
- `history/`: reading history, home history summary, image favorite models, image favorite manager, and image favorite provider.
- `image_favorites/`: image favorite page, home summary, gallery, and photo view UI.
- `local_comics/`: local library, local home summary, downloads, and import/export tools.
- `reader/`: reader page, gestures, chapters, image loading, waterfall flow, clipboard image handling, and reader-only platform interactions.
- `search/`: home search entry, search page, result page, aggregate search, and search query filters.
- `settings/`: settings pages, reader settings, reusable setting controls, and domain-specific setting pages.
- `sync/`: WebDAV data sync, home sync status, app data import/export, and local comic backup/restore.
- `webdav_library/`: WebDAV comic library online reading source for remote directory image structures.

New domains should generally follow this shape:

```text
lib/features/<domain>/
  <domain>.dart
  <domain>_page.dart
  ...
test/features/<domain>/
  <domain>_test.dart
```

External modules should prefer stable feature entry files instead of importing implementation files directly. For example, external code should use `features/reader/reader.dart` for reader capabilities, `features/comic_source/comic_source.dart` for comic source capabilities, `features/comic_storage/comic_storage.dart` for archive metadata and file rules, and `features/webdav_library/webdav_library.dart` for the WebDAV online comic library source.

## App Shell And Runtime

`app_shell/` owns app-level page composition:

- `main_page.dart`: main navigation shell.
- `home_page.dart`: home page composition through feature entries.
- `auth_page.dart`: local authentication page.

Feature domains must not depend on `app_shell/`.

`app_runtime/` owns startup and runtime modes:

- `init.dart`: startup initialization and callback registration.
- `headless.dart`: headless command mode.

Feature domains must not depend on `app_runtime/`.

`app_runtime/` also owns runtime connections between feature domains. Comic-source data synchronization is registered through a callback, and the WebDAV comic source is registered through a runtime source provider. The `comic_source/` domain must not depend directly on `sync/` or `webdav_library/` for those integrations.

Cross-domain comic display widgets declare only the state and provider interfaces needed for rendering. Favorite state, history state, local comic covers, and favorite display preferences are injected by `app_runtime/`; `comic_widgets/` must not import those feature implementations directly.

## Tests

Tests should mirror source directories where possible:

- `lib/features/<domain>/` maps to `test/features/<domain>/`.
- `lib/foundation/` maps to `test/foundation/`.
- `lib/network/` maps to `test/network/`.

When moving source files, move or update the matching tests and fix package imports.

## Migration Checklist

Each structure migration should:

- Use `git mv` to preserve history.
- Update package and relative imports.
- Use `rg` to confirm old paths are gone.
- Run `python .github/scripts/check_structure_imports.py`.
- Update `CHANGELOG.md`.
- Run `flutter analyze`.
- Run relevant tests for the touched domains.

## Boundary Checks

`.github/scripts/check_structure_imports.py` scans Dart imports and exports under `lib/` and prevents dependency direction regressions. The main guarded rules are:

Run `python .github/scripts/check_structure_imports.py --print-feature-dependencies` to inspect the current feature-to-feature import counts. The report identifies candidates for incremental cleanup; it does not require eliminating every cross-feature dependency at once.

- Do not reintroduce source files under retired `pages/` or `utils/` paths.
- `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_shell/`.
- `app_shell/`, `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_runtime/`.
- `foundation/`, `network/`, `utils/`, and `components/` must not depend on `features/` or `pages/`.
- `features/comic_source/` must not depend directly on `features/history/`, `features/sync/`, or `features/webdav_library/`; shared history metadata contracts belong in `foundation/history_contract.dart`, while synchronization and runtime sources are injected by `app_runtime/`.
- `features/comic_widgets/` must not depend directly on `features/favorites/`, `features/history/`, or `features/local_comics/`; tile state, cover providers, favorite display preferences, and state listeners are injected by `app_runtime/`.
- `foundation/app.dart` must remain the `App` singleton entry and must not re-export UI extension buckets.
- Feature domains with stable entries must not be bypassed by external implementation imports.
- Retired `part` libraries in reader, settings, history, favorites, comic details, comic source, and image favorites must not be reintroduced.

For the full and authoritative checklist, use [project_structure.zh.md](project_structure.zh.md).

## Incremental business/UI entry points

Comic sources expose `comic_source_api.dart` for models/services/runtime configuration and `comic_source_ui.dart` for pages/summaries. `comic_source.dart` remains a compatibility aggregate. New business consumers use the API. `SourceUpdateService` owns checking/downloading; pages own interaction and headless callers use the service directly.

Local reading positions are resolved by a pure function in `local_reading.dart`; pages open readers through `routing/local_reading.dart`. `LocalComic` no longer navigates.

CI also runs `check_architecture_dependencies.py` with `dependency_baseline.json` to reject new feature edges and transitive UI dependencies from enrolled business entry points. Aggregate cycles include UI navigation and are not business-only cycles. Enroll entry points incrementally; baseline changes require an explicit responsibility change.

Reader runtime consumes immutable ReaderSettings snapshots from foundation/reader_settings.dart. Settings.readerSettings adapts existing storage; globalReaderSettings preserves global-only options. Dynamic getReaderSetting/getDeviceReaderSetting calls are forbidden in reader runtime. Compatibility APIs for other callers and settings forms remain for later P3 migration.

ReaderPreferences defines storage keys, defaults, validation and slider metadata. ReaderPreferenceStore/bindings provide typed scoped reads/writes. Reader forms use .reader constructors; legacy generic controls remain for other settings domains. Runtime snapshots and Appdata defaults share the field definitions.

Shared fields and binding contracts live in `foundation/preferences.dart`; global network/appearance fields are in `application_preferences.dart`, immutable snapshots in `application_configuration.dart`, and storage adaptation in `GlobalPreferenceStore`. Migrated forms use `.preference`; network/download/theme consumers must not access migrated string keys directly. Reader scope inheritance remains in `ReaderPreferenceStore`.

App sync settings are parsed by `foundation/sync_configuration.dart`; SyncPreferenceStore adapts existing settings/implicitData and captures rollback checkpoints. The service owns transfer/rollback transactions; the adapter neither persists nor starts timers. Settings previews are read-only. DataSyncMode remains exported by its original entry point for compatibility.

Init.init executes an attempt once; ensureInit waits for explicit startup and shares failures. retryInit explicitly starts a new failed attempt. Implementations must clean up partial resources and propagate errors rather than report false readiness. Initialization dependencies must not wait on themselves.

DataSync construction has no runtime side effects; the runtime explicitly calls start. Disposal prevents new tasks and late notifications while allowing active transfers to finish. WindowFrame runs synchronous close guards before awaiting exit tasks in reverse registration order, and owns unfinished tasks transferred by unmounted components. app_runtime/SyncWindowBinding registers the final history-queue/upload wait while mounted; the business service must not access WindowFrame or root context.

Startup boundaries: bootstrap_core.dart assembles real services; core_bootstrap.dart provides injectable, single-attempt dependency ordering. init.dart assembles interactive bindings/background automation. headless.dart starts only shared core and headless JS bindings, never interactive/window/automatic-sync startup. Core failures are cached rather than reopening partially initialized storage. Transitive dependencies through legacy domain barrels remain part of P2/P6 migration.

InteractiveBindings owns interactive subscriptions: the mounted app starts it and disposes it on unmount. Link/share handlers use EventSubscription for serial processing and must check lifetime after awaiting before navigating. Do not restore global text-share initialization flags or unowned event/heartbeat subscriptions.

BackgroundSync owns automatic scheduling while the app is mounted. WebDAV sources perform checks/transfers without a static polling timer. DataSync.stop keeps observing changes to preserve pending state; dispose removes observation. Stopping scheduling must not interrupt transfer commits, and stale-generation ticks must not activate new work.

FollowUpdatesService is separate from the page and exposes a UI-free narrow contract through follow_updates_api.dart. It cancels only owned task handles; runtime bindings own timers and external listeners. Views subscribe to followUpdatesChanges and unsubscribe in dispose; do not restore global State lookup to refresh follow-update pages/previews.

CacheManager owns instance paths, database, scanner and operation queue. CacheManager.open supports independent hosts; start explicitly begins one scan and dispose drains accepted work before closing. Scanners return results without global manager access. Cache operations must not bypass the queue, and directory cleanup must await disposal.

Shared image downloads use SharedRequestStream with an independent RequestScope. Actual subscriptions start the source; the last subscriber cancels source/HTTP work before releasing the source subscription. Consumers release their own subscriptions and must not parent shared requests to one caller scope. Cache hits complete without entering source or network loading.

Reader teardown must not cancel images globally. ReaderImageDownloads owns predownload subscriptions and ReaderImagePrecache owns decoded prefetch listeners. Pending-cache release preserves live consumers and decoded cache entries; Flutter releases the final keep-alive handle at frame end. Expected image cancellation is not reported as loading failure; genuine errors retain existing handling.

LoadingState shares one attempt pipeline for initial loads and manual retries. Each attempt owns a RequestScope, cancelled on replacement/unmount, and results/post-load completion validate attempt identity. loadData/onDataLoaded explicitly receive the scope; consumers must check cancellation after awaits before publishing effects. Do not restore duplicate uncontrolled then/setState paths.

Use UI-free ReaderPageLayout for image-number/display-page conversions; persisted history continues to store image numbers. Gallery ranges are zero-based and end-exclusive, and layout remapping keeps the old first image visible. Consumers must not duplicate cover/grouping/end-of-chapter history formulas. Cross-chapter waterfall and split-image coordinates remain separate policies.

Convert chapter coordinates with ComicChapters.positionAt/chapterIndex. ComicChapterPosition distinguishes source ID, flattened index, group and within-group chapter; history keys retain their existing format. Do not derive cross-group positions from merged allChapters keys, since groups may share source IDs. Image/display-page conversion remains with ReaderPageLayout.

ReaderController owns navigation state and ReaderNavigationState snapshots without importing Flutter, global settings or storage. View navigation uses ReaderNavigationViewport; gestures remain in the UI protocol. The ReaderLocation compatibility mixin is removed; the page assembles the controller directly. Do not reintroduce a page-owned animation state machine. Dispose the controller with its page to suppress late callbacks.

ReaderImagePosition identifies a source image, ReaderPageLayout maps display pages, and WaterfallChapterFlow maps cross-chapter list indices with chapter-ID validation on inverse lookup. ReaderImageSlice regions are normalized painting offsets, not additional source images or history pages. Persist only converted source image numbers under the existing history protocol.

images.dart owns loading/view selection; gallery_view.dart and continuous_view.dart host gallery and continuous/waterfall adapters, chapter_swipe_indicator.dart owns swipe indication. Menu selection uses ReaderImageViewController.currentImageRange instead of concrete State types. The images.dart transitional State export is removed; integration tests that need the implementation import continuous_view.dart directly.

ChapterImageLoader depends only on injected chapter access and error callbacks, with no global manager lookup. loadReaderChapterImages adapts legacy storage/sources: stable chapter IDs and download availability belong to the adapter, while local-first/fallback/cancellation belong to the policy. Tests separately cover real-storage compatibility and behavior without globals.

ReaderController also owns ReaderContentState with copied immutable image lists. Loads commit by ReaderContentLoad identity; stale owners cannot cancel replacements. Keep loading active during layout preparation. Views coordinate rebuilds, so content commands do not emit notifications during build/init. Activate loaded waterfall chapters through replaceChapterImages.

ReaderHistoryWriter owns one reader’s delayed saves and exit-flush scheduling through injected storage/error callbacks. Coordinate conversion stays in the adapter. Disposal cancels pending timers without cancelling or duplicating accepted storage operations; database ordering belongs to storage.

WaterfallController owns chapter insertion/reset, prefetch/navigation state and request scopes; continuous views use the WaterfallFlowView query protocol. Prepending returns source-image count for view-owned anchor restoration. Navigation/disposal invalidate old requests and frame callbacks. The controller has no Flutter, ReaderState, global source or storage dependency; composition supplies access.

Gallery receives content/configuration through ReaderGalleryData and navigation through ReaderController; it must not locate ancestor ReaderState or read global settings. images.dart composes comments, UI callbacks and image access. ReaderImageViewController is defined independently in reader_viewport.dart; all callers import it directly; the page no longer re-exports it. Reuse controller image snapshots and preserve image-processing page semantics during structural migration.

Continuous views receive settings through ReaderContinuousData, active chapter/content through ReaderController, and chapter access/UI effects through explicit callbacks. Do not restore ancestor ReaderState or global settings lookup. Read active controller content immediately after chapter changes instead of caching it until a parent rebuild. images.dart shares viewport registration and image-byte adaptation.

progress_bar.dart presents the bottom bar, progress slider and page text through explicit values/callbacks; the slider owns its focus node. scaffold.dart decides chapter navigation, business actions, placement and menu lifecycle. Do not introduce ReaderState/global settings into progress components. ReaderBottomBar.height is the single bottom-bar height declaration.

ReaderStatusInfo owns clock/battery polling; ReaderBatteryRead injects platform access returning ReaderBatterySnapshot. Scaffold controls visibility and placement only. Allow at most one read per dependency generation, reject results after disposal/replacement, and distinguish unsupported hardware from transient failure. Stop scheduling even when native Futures cannot be cancelled.

ReaderTopBar receives titles/actions/back callbacks; ReaderBrightnessPanel receives values/change callbacks. Scaffold owns availability/visibility, preference scope and persistence, navigation and sidebar lifecycle. Panels must not locate reader State or write settings directly.

ReaderImageExporter coordinates exports using ReaderImageSelection identity captured before reading. The shell supplies cache/files and platform actions; never rename selected images using current page state after an await. ReaderImageSelectionOverlay owns its entry/waiter and completes on replacement/disposal. Exit prevents only platform operations not yet handed off.

readerSettingEffects resolves ordered setting effects only. ReaderPreferences supplies fixed keys, with explicit prefix/unknown-key compatibility. The shell checks validity while applying effects; keep widgets/platform calls outside the policy module and read current values in the application adapter.

ImageFavoriteActions is a history business entry with injected storage callbacks, depending only on favorite models and constants. UI must not be transitively reachable. Reader adapters own selection, translation and feedback; actions return explicit outcomes. The existing history.dart UI barrel is not a dependency for new favorite business modules.

ReaderSession owns ReaderHistoryWriter and ReadingSessionTracker and gates timing on both content readiness and foreground state. Flutter lifecycle, automatic-reading pause and exit synchronization use adapters. Exit immediately submits pending progress and stops timing, drains all accepted progress (including the exit flush) and duration writes, then notifies the application once; late content/lifecycle events cannot restart it. ReaderHistoryWriter.dispose returns the same completion Future and reports storage errors through its injected callback. Delayed saves and exit both call asynchronous addHistory, with no separate flush callback or synchronous storage entry. Desktop readers register a session exit task and transfer its unfinished completion on unmount; normal window shutdown waits for it and the sync it triggers.

ReaderImageCachePolicy owns memory thresholds and query validity for one reader. The page adapts the memory plugin, logging and PaintingBinding cache. Exit restores the existing 100 MB limit and invalidates pending queries; repeated configuration accepts only the latest result. It neither cancels native Futures nor arbitrates cache ownership across multiple readers.

ReaderVolumeController owns an injected event stream and navigation callbacks without Flutter/page dependencies. Toggling immediately invalidates old input; reconnection waits for StreamSubscription.cancel; disposal prevents new subscriptions. Previous-chapter-end and next-chapter fallback behavior is preserved. volume.dart only adapts venera/volume; the page selects Android support and logs errors. Flutter retains native activation/deactivation acknowledgement and error handling; Dart cancellation is not native acknowledgement.

ReaderWindowController owns the close listener and fullscreen request queue through injected window, frame and navigation callbacks, without context lookup. ReaderState captures its ancestor WindowFrame and root Navigator during dependency initialization, retaining overridable assembly/disposal seams. Exit removes the listener synchronously, then drains accepted native operations and restores windowed mode. Native operations cannot be forcibly cancelled; concurrent readers still require shared-window arbitration at runtime.

ReaderOrientationScope must wrap the Navigator and be owned by the application tree. ReaderOrientationCoordinator depends only on orientation/error callbacks and owns handles instead of static Widget States. ReaderOrientationState acquires/releases handles and refreshes UI. DeviceOrientation mapping stays in orientation.dart; the business enum has no platform dependency. Missing scope in an Android reader is an assembly error, with no hidden global fallback.

Navigation behavior tests depend only on ReaderController/ReaderNavigationViewport and injected error reporting, without a page mixin or global log muting.

History data is exposed through history_api.dart; history_model.dart imports no HistoryManager or pages. The legacy history.dart UI barrel exports the data entry; history_manager.dart no longer exports the model. applyReaderHistoryProgress maps reading coordinates to history fields, while the page gates loading and schedules persistence. Existing fields, the fromMap compatibility constructor and descriptions remain pending further storage decomposition without implicit data changes.

HistoryRepository owns schema migration, queries/deletes and progress/duration transactions on a caller-owned Database, without connection, cache or notification ownership. historyFromRow in history_row.dart decodes SQLite fields; History no longer directly imports SQLite or exposes fromRow. HistoryManager retains the asynchronous queue, connection lifetime, cache and notifications, with no direct history-table SQL. The data entry must not re-export managers or pages.

Conditional deletion captures complete favorite identities at submission and tests that set inside the deletion transaction; predicate/deletion failures roll back the batch. The manager computes retention cutoff, the repository uses strict less-than. Recent history remains limited to 20 and duration ranking sorts by duration then reading time descending.

HistoryCache keys both identity guards and recently written records by (id, type), with injected identities/load callbacks. Writes refresh only that ID's actual source set, supporting id-only replacement and legacy compound identities. Refresh evicts missing identities, close clears state, and the existing ten-entry write-order eviction remains. Cached mutable identities are validated before delivery. This changes neither database schema nor write ordering.

Asynchronous history submission captures a History.copy with independent read keys, database path and manager generation before enqueueing. External mutable records must not be read later as write inputs. Only the current generation reloads persisted data into cache and notifies; close/reopen does not redirect accepted writes and old completions cannot contaminate the new lifetime. Progress, duration and all history deletions share the manager queue, each using an isolate-owned connection in acceptance order. Failures propagate to callers and are logged without poisoning later work. Batch deletion identities and favorite sets are captured before enqueueing. waitForAsyncWrites also drains writes accepted during the wait; callers needing final results, exports, migrations or shutdown must await, while ordinary UI deletions refresh through completion notifications. This guarantee is per manager and neither cancels accepted operations nor promises crash/forced-termination durability.

Desktop startup enables window_manager close interception before showing the window. Mounted WindowFrame listens for native close events and routes them through the same guards and asynchronous exit tasks, removing its listener on unmount. Explicit forced shutdown invokes process exit at most once. This covers plugin window-close events, not a guarantee for system shutdown, macOS application Quit or forced process termination.

Progress writes update reading time, chapter/group, page, read keys and maximum page; existing metadata and cumulative duration must not be overwritten by a progress snapshot. New rows still receive full initialization data. Capture metadataUpdaterFor before network work to bind identity and database generation: it updates only supplied metadata fields, never inserts missing rows, preserves omitted fields and permits explicit empty strings. Source refresh and cover resolution use it. importHistory deliberately replaces progress and metadata in one transaction while retaining the existing duration import policy.

The favorites_api.dart data entry exports only the three models in favorite_models.dart. The existing favorites.dart remains the UI/manager barrel; favorites_manager.dart no longer implicitly exports models. Cross-feature model callers use the data entry; same-feature callers may import implementations. favoriteItemFromRow in favorite_row.dart exclusively decodes SQLite Row, while FavoriteItem.withTime accepts the raw timestamp without parsing or regenerating it. Existing JSON source mapping, removal of only the first empty tag, derived-model construction and display-setting reads remain unchanged and require explicit compatibility decisions before alteration. SQL, caches and follow-update orchestration remain in the manager pending further decomposition.

FavoritesRepository supplies basic favorite queries on a caller-owned Database: folders/order, counts/order bounds, folder contents, deduplicated aggregates/per-folder copies, complete identity existence and containing folders. The manager retains connections, isolates, caches and notifications; synchronous/asynchronous reads share the implementation. Folder listing excludes the existing two metadata tables and loads ordering in one query: missing values default to zero, duplicate rows keep their first value and orphan rows are ignored; tie comparison is unchanged. Aggregation retains the first complete identity in input folder order, preserving different sources. Read-side table identifiers escape double quotes. Further write, migration and search progress is described below; repository migration remains incomplete.

FavoritesRepository owns transactions for single moves, batch moves and batch copies: destination insertion and source removal succeed or roll back together. Only after success does the manager update counts, identity/follow-update state and notify. Single moves preserve the source when the destination identity exists and prepend successful transfers. Batches retain existing destination records and append in input order, including order increments for duplicates; batch moves remove matching source records. Same-folder batches return immediately to prevent self-deletion. Transfers retain the original eight-field copy policy; follow-update/translated-tag copying is unchanged in this unit.

For favorite insertion the manager supplies translated tags, front/end preference and explicit order. FavoritesRepository checks duplicate identity, computes placement, inserts and optionally sets last_update_time in one transaction; legacy tables without that column still skip it. Folder order updates are atomic. Tags use bound values while retaining the existing ID-only API semantics across source types. updateInfo changes only name, author, cover and tags, preserving time/order/translated tags. After success the manager maintains counts, identities, follow-update state and existing notification behavior.

Favorite record deletion is transactional and returns actual complete identities removed per folder. Duplicate requests are coalesced; missing rows do not affect caches or notifications. After commit the manager updates counts and identity references, then removes covers with no remaining folder references. Synchronous cover-file removal failures are logged separately without undoing committed data or suppressing notifications. Cross-folder deletion rolls back as a unit; folder DROP and folder_order cleanup share a transaction. Folder-level cover collection and whole-database clearAll lifecycle retain their existing behavior pending further work.

FavoritesRepository owns folder creation, rename and network-link persistence; the manager retains name/duplicate validation and preference updates. Renaming the table, folder_order and folder_sync must commit together. Folder deletion clears both metadata tables so recreation cannot inherit an old link. Creation initializes counts before notifying; failed rename must not change settings or caches.

FavoritesRepository.initializeMetadata creates folder order/link tables. migrateTranslatedTags checks every existing folder without stopping at an already-migrated folder; missing columns and backfill share a transaction with an injected translation function, leaving existing columns unchanged. prepareForFollowUpdates atomically adds the three tracking columns; clearData resets only the new-update flag and preserves stored times. The manager retains default tracking-folder selection, preference fallback and cache refresh. Initialization connection reuse/failure recovery and whole-database clearing lifecycle remain separate work.

Folder reads with optional limits, record reordering and folder/global searches now belong to FavoritesRepository. Reorder updates full identities in one transaction; the manager retains validation, failure logging and success notifications. The first token retains SQLite LIKE behavior, including wildcards and translated tags; secondary tokens preserve case-sensitive matching against original fields. Global search retains the first full identity and stops after a folder takes candidates above 200, before secondary filtering; this is not a strict result limit. Read-later preserves SQLite zero/negative LIMIT semantics. Read-triggered movement, tag editing, export, follow-update data and connection lifecycle remain pending.

The favorite manager and identity-cache isolate no longer execute SQL directly. The repository owns identity lists, tag replacement, export reads, read-triggered position/time updates and tracking reads/writes; tracking row decoding reuses favorite_row. Read-triggered writes span all participating folders in one transaction, skip read-later, use one operation timestamp and update tracking caches/notifications only after commit. Unknown movement settings update time only; none still only acknowledges tracking. onRead removes async without await while retaining its void interface, so callers can catch storage failures synchronously. Tracking comparison and writing share a transaction, preserving same-version flag clearing and missing-identity errors. Tag editing still updates an ID across source types; export preserves original fields/times without explicit ordering. Connection initialization/close/clear ownership, identity hash collisions and asynchronous refresh generations remain pending.

FavoriteIdentityIndex stores reference counts using complete (id, type) keys; tracking sets use the same identity instead of treating XOR hashes as unique keys. Snapshots use generations and merge actual reference counts committed locally while a snapshot was in flight. Failure preserves current state; initialization/close clear the index and invalidate old generations. Add/move/copy/delete reconcile affected identities before notifying, with repository queries batched by folder and 400 identities; folder deletion/rename also restart snapshots to avoid old table names. The blind reduceHashedId decrement entry was removed. refreshHashedIds and the test wait entry retain their existing names but no longer use hash identities internally. This does not complete shared initialization Futures, connection disposal, clearing paths, cancellation/draining of all isolates or performance acceptance.
