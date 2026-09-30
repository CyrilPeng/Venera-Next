# Architecture and Maintainability Optimization Plan

中文：[架构与可维护性优化方案](optimization_plan.zh.md)

Date: 2026-09-30. Status: proposed, not implemented. This document is not a release-date commitment.

## 1. Scope and approach

Improve maintainability while preserving application behavior and stored data. Continue using the existing `app_shell`, `app_runtime`, `features`, `foundation`, `network`, and `routing` structure. Introduce model, service, persistence, and view boundaries only where they serve real responsibilities.

This work excludes product expansion, visual redesign, wholesale state-management replacement, package splitting, bulk dependency upgrades, and unvalidated database redesign. Keep those changes separate if needed.

The current [project structure rules](project_structure.en.md) remain authoritative. New entry points and constraints become effective with matching documentation, checker, and test updates.

## 2. Baseline and limitations

The initial review used the working tree on 2026-09-30, including uncommitted reader/settings changes. Record an exact commit and working-tree delta before implementation.

| Measurement | Observation |
|---|---|
| Source | 230 Dart files in `lib`, approximately 67,641 lines including comments and blanks |
| Tests | 96 `*_test.dart` files; this is not a coverage measurement |
| Structure check | Dependency report completed successfully; allowed feature dependencies still contain cycles |
| Analysis | `flutter analyze --no-pub` reported 2 errors and 25 infos; both errors concerned missing `build_tool` imports under `build/` |
| Settings | Approximately 214 `appdata.settings[...]` accesses, excluding other dynamic access forms |
| Cleanup candidates | `foundation/channel.dart` and `components/components.dart` were not reached from the main entry point's static dependency graph |
| Runtime validation | No full test suite, five-platform build, or performance benchmark was run during this review |

Evidence includes source updates owned by `ComicSourcePage` and called from headless mode; navigation inside `LocalComic.read()`; reader views writing ancestor state; dynamic settings; mixed SQL/business responsibilities in favorites; static WebDAV state; initialization without a shared in-flight future or direct failure propagation to waiters; and synchronization subscriptions/window operations started in a constructor.

## 3. Target boundaries

| Area | Responsibility |
|---|---|
| `app_shell` | Application pages and navigation composition |
| `app_runtime` | Dependency wiring, startup ordering, execution modes, lifecycle bindings |
| `routing` | Turn data-only navigation targets into page transitions |
| Feature models/policies | Business data, calculations, state transitions |
| Feature services | Use cases and task coordination through narrow dependencies |
| Feature repositories/adapters | SQL, files, source runtime and concrete I/O |
| Feature UI | Rendering, input, presentation and navigation intentions |
| `foundation` / `network` | Shared technical infrastructure with no feature-manager or page dependency |

Lightweight Flutter notification primitives are acceptable in services where useful. Pure business policies should remain independently testable. Place contracts in their owning domain instead of creating a growing global `common` module.

Introduce narrow business and UI entry points where needed, for example `comic_source_api.dart` and `comic_source_ui.dart`; finalize naming during implementation. Business exports must not transitively expose pages. Keep old barrels only during migration. Internal imports remain allowed within a domain; cross-domain consumers use public entry points.

Do not demand an acyclic aggregated feature graph: UI navigation may form cycles. Require an acyclic business dependency graph and no business-to-UI dependencies. Narrow existing shared models before considering moving their ownership.

## 4. Phases and dependencies

| Phase | Scope | Dependencies | Relative effort / risk |
|---|---|---|---|
| P0 | Baseline and quality boundaries | None | Small–medium / low |
| P1 | Evidence-based cleanup | P0 | Small / low |
| P2 | Business/UI separation and first services | P0 | Medium / medium |
| P3 | Typed settings | P2 entry-point agreement | Medium / medium–high |
| P4 | Initialization and task lifetimes | P2 | Medium / medium–high |
| P5 | Reader decomposition | P3, P4 | Large / high |
| P6 | Storage, favorites, import and synchronization | P2, P4; P3 for settings | Large / high |
| P7 | Source parsing and repeated technical workflows | P2, P4; reuse P6 findings | Medium–large / medium–high |
| P8 | Remove adapters and complete validation | P1–P7 | Medium / medium |

Default to one implementation stream in phase order. P5 and P6 can be reordered based on risk; edits to shared files must remain coordinated. Effort labels are comparative, not delivery estimates.

## 5. Work and exit criteria

### P0: Reproducible baseline

Record the starting commit, local changes, known failures and skips without resetting, stashing or committing user work. Exclude confirmed generated output from analysis; preserve real source/test coverage. Capture fresh tests, coverage and dependency reports. Extend dependency reporting to distinguish business/UI edges, transitive exports and strongly connected components. Existing exceptions need reasons and removal phases; reject new exceptions.

Benchmark chapter transitions, seeking, long-image scrolling, scanning, sync and imports on fixed devices, build modes and synthetic fixtures. Repeat runs to establish noise before defining regression limits.

Exit: no errors/warnings in maintained source, tracked infos, reproducible test status, tested boundary rules and documented performance scenarios. Baseline failures are not treated as passing results.

### P1: Cleanup

Check production, test and protocol references for `Channel<T>` and the component barrel, including structural checker assumptions. Remove unused implementations and dedicated tests only after confirming no maintained use. Classify other candidates as removable, test utilities, compatibility, dynamic entry points or unresolved.

Review tracked temporary artifacts and duplicate tools without recursively cleaning user directories. Check dependency use in native registration, assets, JavaScript and platform builds, not just Dart imports.

Exit: every deletion has evidence and validation; no arbitrary line-reduction target or replacement code with no production purpose.

### P2: First service boundaries

Introduce narrow public entry points incrementally. Extract `SourceUpdateService` for checking, downloading, cancellation, deduplication, repository revision handling and results. Reuse repositories, managers and installation mechanisms. Pages own dialogs; CLI calls the service directly and preserves arguments, structured output and exit behavior. Track behavior fixes separately.

Separate `LocalComic.read()` into initial-position/navigation-target calculation and routing. Keep stable chapter IDs and history semantics. Define only necessary chapter, history, favorite and sync-participant contracts.

Exit: services and CLI do not import page classes; local models do not navigate; source update logic can be tested without widgets; concurrency, cancellation and revision behavior remain compatible; business exports do not expose UI.

### P3: Typed settings

Inventory defaults, ranges, missing values, legacy migration and scope precedence from existing behavior/tests. Add immutable `ReaderSettings` and one resolver for global/device/comic inputs, enablement flags and effective values. Preserve JSON keys and persistence through an adapter. Migrate reader, gesture, layout and settings consumers incrementally.

Centralize invalid-type, enum and range handling. Preserve sync exclusions and existing unknown-field behavior. Follow with sync, network and appearance settings. Prevent new dynamic accesses in migrated modules.

Exit: reader code no longer reads dynamic maps; inheritance, legacy long-press migration and live updates are tested; atomic writes, backup recovery and old-config round trips remain compatible.

### P4: Lifetimes

Cache in-flight initialization, define idle/starting/ready/failed states, propagate failures to waiters and specify retries. Audit `ensureInit()` for self-waiting and startup-order hazards. Split core bootstrapping from interactive and headless bindings; plugin-dependent code may still initialize Flutter bindings without requiring a Navigator.

Inject paths, clients, stores and clocks. Move timers/window subscriptions out of constructors into explicit start/dispose methods owned by runtime composition. Bind reader loads and prefetch to sessions; shared requests survive until their last owner releases them. Review `RequestScope.dispose` separately from cancellation. Preserve atomic import commit behavior. Replace `GlobalState.find` incrementally with explicit controllers/callbacks.

Exit: one execution for concurrent initialization, finite failure propagation, no duplicate subscriptions, no post-disposal callbacks or cross-owner cancellation; migrated service tests do not require production singleton resets.

### P5: Reader

Extract a reading-position model distinguishing source image index, stable chapter ID, visual page and split-page offset. Preserve persisted position semantics. Extract mapping, first-image, comment-page, mode-switching and cross-chapter policies before moving views.

Introduce `ReaderController` with immutable observable state and commands. Remove child writes to ancestor state. Inject chapter access into the existing loader while preserving local-first reading and online recovery. Separate gallery, continuous and waterfall views using a viewport protocol; retain mode-specific behavior. Split scaffold into shell, menus, progress and settings components.

Reuse `ReadingSessionTracker`, `AutoReadingController` and `WaterfallChapterFlow`. Session/platform adapters own history, reading time, orientation, brightness, volume and sync triggers.

Exit: all seven modes, automatic selection, page mapping, split pages, comment endings, auto-reading pause reasons, long-image boundaries, chapter waits/retries, menu locking, accessibility, keyboard behavior and live settings pass regression checks. Seeking/disposal cannot apply stale state. Performance remains within P0 limits.

### P6: Persistence and synchronization

Separate models from SQLite mapping/query/migration code. Keep transactions explicit and reuse `sqlite_connection.dart`. Split favorites CRUD, sorting, read-later and follow-update coordination while preserving tables and identity semantics.

Separate local directory access, metadata, download queues and recovery. Reuse `DocumentImportSession`, `comic_storage` and `local_storage_guard`. Split WebDAV configuration, discovery, snapshots/cache, scheduling and source adaptation; inject existing operations/cache into instances.

Split app-data sync scheduling, transport, snapshot transfer and presentation state. Move lifecycle/window triggers to runtime. Preserve import-without-reupload behavior, pending flags, excluded settings and version/conflict rules. Schema changes are not a default part of this phase.

Exit: legacy fixtures round-trip; fault injection leaves no partial library record or replaced snapshot; ordering, notifications, storage/import exclusion, three sync modes, restart persistence, WebDAV paths/cache invalidation and incremental results remain compatible.

### P7: Parsing and shared mechanisms

Split source parsing by capabilities while retaining validation and error context. Preserve `assets/init.js`, JS API/callback names, source identity and persisted formats. Test with minimal/synthetic sources, not external live providers.

Compare update, image/archive download, sync and import mechanisms. Extract only actually duplicated semantics such as progress, limits, retries or cancellation; retain specialized HTTP/JS/file adapters. Avoid a universal task framework.

Use structured errors for new boundaries, distinguish failure/cancellation/unsupported operations, preserve underlying errors and translate at presentation boundaries. Adapt existing `Res<T>` incrementally. Review version comparison, paths, sorting, archive metadata and date formatting for real duplication.

Exit: source contracts remain compatible; cancellation is not success or ordinary retryable failure; errors retain source/capability/operation context; every shared abstraction has real consumers and replaces duplicate implementations.

### P8: Finish and enforce

Remove completed migration adapters, forwarding methods, globals and outdated comments. Gradually restore asynchronous-context and unrelated-collection lint rules, document local exceptions and complete boundary type annotations.

Enforce business dependency direction and cycles in CI. Review fresh coverage by changed domain and policy behavior. Run full tests, applicable platform builds/manual checks and P0 performance scenarios. Update structure docs, changelog and remaining debt inventory.

Exit: all final criteria below are met; incomplete validation remains explicitly incomplete.

## 6. Reviewable work units

Suggested commit/PR sequence, split further when necessary:

1. Baseline and analysis scope.
2. Business/UI dependency reporting and checker tests, including relative/conditional imports, exports and parts.
3. Confirmed unused-file cleanup.
4. Source business/UI entry points.
5. Source update service.
6. CLI and reading-navigation separation.
7. Typed reader settings and persistence adapter.
8. Migrate reader/settings consumers.
9. Initialization concurrency and failure contract.
10. Core/interactive/headless bootstrapping.
11. Reader request ownership.
12. Reading positions and mapping policies.
13. Reader controller/session.
14. Reader view/scaffold decomposition.
15. Favorites/history persistence separation.
16. Local library/import/download separation.
17. Instance-based WebDAV library.
18. App synchronization and remaining typed configuration.
19. Source parser/shared technical primitives.
20. Adapter removal, lint restoration and final validation.

Do not combine relocation, data-format changes, behavior changes and dependency upgrades in one unit. This proposal does not automatically authorize implementation commits or PR creation.

## 7. Verification

Use policy tests for settings/mapping/state transitions; old fixtures for configuration, databases, history, sources, snapshots and archive metadata; fault injection for startup, cancellation, timeout and late completion; widget tests for locking, gestures, settings, seeking, large text and safe areas; integration tests for offline fallback, resumed downloads, import exclusion and sync import; and headless subprocess smoke tests in addition to services tested without a widget tree.

Platform checks cover Android SAF/volume/orientation, Windows close behavior, iOS lifecycle, and Linux/macOS headless/file behavior. Run applicable builds on their proper runners. Unavailable validation must be marked unverified, never reported as five-platform success.

Reuse CI structure checks, Python tests, Git dependency audit, formatting, `flutter analyze --no-fatal-infos --fatal-warnings` and `flutter test --coverage`. Start with relevant tests and expand at cross-domain milestones. Do not add implementation-mirroring tests for documentation or adequately covered mechanical moves. Prefer observable behavior over private-field assertions. Use synthetic or approved minimal fixtures without personal libraries or credentials.

## 8. Compatibility and rollback

Default to preserving schemas, keys, JS/CLI contracts and file layouts. Any required format change needs explicit versioning, legacy fixtures, backups, idempotent migration, atomic failure behavior and cross-version read/write constraints. Reverting code does not roll back data.

Use small commits to isolate reader behavior, startup composition, services and request adapters. Preserve transaction/storage locks. Restore backups only with no active writers and without overwriting unknown newer data. Do not retain extra abstractions if they fail to reduce real coupling.

Update CHANGELOG before committing and use `<type>(<scope>): <Chinese description>`, for example `refactor(comic_source): 将漫画源更新流程迁出页面`. Preserve file history on moves and record validation alongside changes.

## 9. Final acceptance

- Business models/services and business exports do not depend on pages, root context or concrete Widget State.
- Key business cycles are removed; retained UI cycles are explained; CI rejects new business cycles and reverse dependencies.
- Reader state, configuration resolution and page mapping have explicit, testable owners.
- Migrated services expose dependencies and finite startup/failure/disposal behavior; tests do not rely on resetting production globals.
- Deletions have evidence and completed migrations leave no unused compatibility layers.
- Data, JS, CLI and behavior regressions pass with no unexplained new failures/skips.
- Performance meets P0 limits; fresh coverage includes critical policies and failure paths.
- Documentation, architecture checks, changelog and implementation agree.

Treat handwritten files above roughly 800 lines as review prompts, not hard failures. Track dependency violations, dynamic configuration accesses, production globals and cleanup candidates by phase. Neither total line count nor one aggregate coverage percentage defines success.

## 10. First execution batch

- [ ] Record baseline and existing working-tree changes.
- [ ] Capture tests/dependencies and settle entry-point checks.
- [ ] Resolve Channel and component-barrel candidates.
- [ ] Extract source business entry points and update service.
- [ ] Migrate UI/CLI and verify cancellation, concurrency and output compatibility.
- [ ] Extract reading navigation and verify history/chapter restoration.
- [ ] Review actual effort before scheduling later phases.

Current progress: P0 tooling and working-tree test baseline are complete; device performance and platform validation remain pending. See the [execution record](optimization_progress.en.md).
