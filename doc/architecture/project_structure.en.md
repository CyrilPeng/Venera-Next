# Project Structure

Chinese version: [project_structure.zh.md](project_structure.zh.md)

This document is the English companion for the repository structure rules. The Chinese document is the default maintenance entry and contains the full boundary checklist used during structure refactors.

## General Principles

- `app_shell/` contains app shell entry points, such as authentication, home page composition, and the main navigation shell.
- `app_runtime/` contains runtime assembly, such as startup initialization, update checks, debug reload, and headless command entry points.
- Business code should be grouped by feature domain under `features/<domain>/`.
- Do not add new source files under `pages/`; app-level entry points belong in `app_shell/`, and business pages belong in the corresponding feature domain.
- `foundation/` contains cross-domain application foundations, including app state, initialization protocols, async queues, Dart extensions, constants, logging, localization, file system helpers, image processing, image provider bases, platform channels, and shared data infrastructure.
- `components/` contains reusable UI components. Components that only serve one business domain should live inside that feature domain.
- `network/` contains general network, cache, request, and file transfer infrastructure. Business-specific download tasks and API wrappers should remain in their owning feature domain.

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

- Do not reintroduce source files under retired `pages/` or `utils/` paths.
- `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_shell/`.
- `app_shell/`, `features/`, `routing/`, `foundation/`, `network/`, `utils/`, and `components/` must not depend on `app_runtime/`.
- `foundation/`, `network/`, `utils/`, and `components/` must not depend on `features/` or `pages/`.
- `foundation/app.dart` must remain the `App` singleton entry and must not re-export UI extension buckets.
- Feature domains with stable entries must not be bypassed by external implementation imports.
- Retired `part` libraries in reader, settings, history, favorites, comic details, comic source, and image favorites must not be reintroduced.

For the full and authoritative checklist, use [project_structure.zh.md](project_structure.zh.md).
