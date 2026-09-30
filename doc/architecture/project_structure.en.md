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

DataSync construction has no runtime side effects; the runtime explicitly calls start. Disposal prevents new tasks and late notifications while allowing active transfers to finish. Only app_runtime/SyncWindowBinding owns the window-close wait and its mounted listener lifecycle; the business service must not access WindowFrame or root context.

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

ReaderController owns navigation state and ReaderNavigationState snapshots without importing Flutter, global settings or storage. View navigation uses ReaderNavigationViewport; gestures remain in the UI protocol. ReaderLocation is transitional forwarding only: do not reintroduce a page-owned animation state machine. Dispose the controller with its page to suppress late callbacks.

ReaderImagePosition identifies a source image, ReaderPageLayout maps display pages, and WaterfallChapterFlow maps cross-chapter list indices with chapter-ID validation on inverse lookup. ReaderImageSlice regions are normalized painting offsets, not additional source images or history pages. Persist only converted source image numbers under the existing history protocol.

images.dart owns loading/view selection; gallery_view.dart and continuous_view.dart host gallery and continuous/waterfall adapters, image_view_support.dart shares image helpers, and chapter_swipe_indicator.dart owns swipe indication. Menu selection uses ReaderImageViewController.currentImageRange instead of concrete State types. New business code must not depend on transitional State exports.
