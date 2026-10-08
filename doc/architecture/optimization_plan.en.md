# Architecture and Maintainability Optimization Plan

See the [acceptance inventory](optimization_acceptance.en.md) for current item-level status. Original checklists and dated entries below retain their historical meaning and are not the complete current status.

From 2026-10-09, use [section 11](#remaining-work) for remaining batches, verification cadence and evidence reuse. The original scope and exit criteria in sections 5 and 9 remain effective.

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

Reuse CI structure checks, Python tests, Git dependency audit, formatting, `flutter analyze --no-pub --fatal-infos --fatal-warnings` and `flutter test --no-pub --coverage`. Select targeted, batch and final verification using [section 11](#verification-cadence); a cross-domain edit or commit alone does not trigger a full run. Existing required CI checks remain. Do not add implementation-mirroring tests for documentation or adequately covered mechanical moves. Prefer observable behavior over private-field assertions. Use synthetic or approved minimal fixtures without personal libraries or credentials.

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

<a id="remaining-work"></a>

## 11. Remaining work and completion plan (2026-10-09)

### 11.1 Baseline and scope

The implementation baseline is `57b8c888d9ab46c7ba428a3fc46d59c1665dc10e`, with a clean working tree at review. The original 52 items remain **24 I / 27 P / 1 U**. Overall **70% (65%–75%)** is a judgment based on remaining effort and risk; 46.2% only counts I rows. Replanning adds no implementation progress and does not require rerunning established baseline checks.

That baseline has historical evidence of 4844 full-suite passes, two existing skips, clean strict analysis and a successful Windows release build. Evidence applies only to its recorded source, inputs and toolchain. Local Flutter 3.41.6 / Dart 3.11.4 results do not replace declared SDK 3.41.4, other platforms or performance acceptance.

Remaining scope is fixed to the 28 P/U items below. Recheck completed items only when a new change invalidates their evidence. Defects blocking original exit criteria, data safety or compatibility belong to the relevant batch; new features, visual changes and nonblocking further improvements become follow-up work. Merely relabeling an original P/U item as technical debt cannot complete it.

### 11.2 Four completion batches

Use one implementation stream, normally R1 → R2 → R3 → R4, while preparing R4 environments and performance comparisons from the start. Every open item has one technical completion owner below; contributions from other batches reference that same item. Original platform-related exit conditions still require R4 evidence.

| Batch | Original acceptance items | Combined scope | Technical completion and verification |
|---|---|---|---|
| R1: Lifetimes and business entry points | P4.2, P4.4, P4.5, P4.6, P5.7, P7.2, P7.4, P7.5, P7.6 | Inventory all ensureInit/failure resources and remaining source, account, JS, native and reader-session tasks together; group ownership/cancellation/publication for quick favorite deletion, export, bulk additions, network imports and external opening; reuse existing shared mechanisms and technical rules | Inventory production callers with owner, admission, actual completion, late failures and release. Verify JS/minimal synthetic source compatibility, distinct cancellation/unsupported/error outcomes and removal of real duplication. Run changed behavior tests during work; combine affected runtime, source, network, reader and favorite regressions at batch completion |
| R2: Storage, synchronization and settings | P3.3, P3.4, P3.5, P6.2, P6.3, P6.5, P6.6, P6.7 | Remaining typed consumers and legacy/import/sync round trips; all writers, cross-process snapshot locks, import/download/migration/recovery exclusion, three sync modes and pending state; favorite CRUD/order/read-later/tracking and post-commit notification | Synthetic legacy data verifies reopen, recovery, failure atomicity and commitment. Close the known gap where a committed write followed by tracking/notification failure skips ordinary view refresh; preventing write replay is insufficient notification evidence. Combine configuration, favorite, history, local-library, sync and WebDAV regressions at batch completion |
| R3: Architecture and compatibility cleanup | P0.4, P2.1, P2.5, P8.1, P8.2, P8.3 | Review all 28 pending files and classify the original 46-file SCC; narrow cross-domain contracts, remove fully migrated forwarding entries/fields/debug/reset/stale comments, restore lint and boundary types | Business cycles and reverse UI dependencies satisfy existing gates; retained UI navigation cycles have reasons. No weakened rules or mechanical reclassification. Run structure/architecture checks and relevant Python tests, strict analysis and affected consumer tests; R4 supplies the complete coverage trend |
| R4: Final acceptance and delivery | P0.3, P0.5, P2.3, P8.4, P8.5 | Candidate full suite/coverage, complete real CLI, declared SDK, five-platform builds/install/startup/manual scenarios, six performance comparisons and final deletion/debt reports | Complete L3 below against the same candidate inputs, then review all original 52 items and section 9. Missing devices/results stay unverified with a named validation environment; they do not complete the plan |

R1–R3 code and targeted verification do not automatically turn an original item into I while platform, performance or cross-batch evidence is missing. Each batch reports closed original items, missing evidence and blockers for the next batch. Commit or test counts do not determine progress percentages.

### 11.3 Prepare environments and performance comparisons early

- At the start, check availability of five-platform runners, declared SDK 3.41.4, real CLI execution and manual scenarios once. Separate validation environments do not change the local SDK, dependency versions or lockfiles. Do not repeatedly retry an unavailable check without an environment change.
- Fix the device, build mode and synthetic data, and identify a reproducible original-plan comparison version. Measure chapter transitions, rapid page jumps, long-image scrolling, directory scanning, synchronization and bulk import at least three times each for timing, memory and variation. Set allowed regression limits before measuring the final candidate. If only `57b8c88` can be measured as a baseline, that comparison proves the impact of remaining changes only; complete original-plan performance acceptance still has a gap.
- Retain synthetic data, isolated test paths and the existing constraints against opening real applications/browsers or using personal data. Device/manual checks await an authorized test environment. Code completion can proceed, but synthetic unit tests cannot stand in for missing platform results.

<a id="verification-cadence"></a>

### 11.4 Verification levels and full-run triggers

**Plan one final local full-suite run, including coverage, for the remaining work. A small fix, commit or batch completion no longer automatically triggers a full test run or build.** This is the default for avoiding repetition; necessary extra runs require a trigger below. Existing required CI checks remain unchanged.

| Level | Trigger and scope | After passing |
|---|---|---|
| L0: Documentation and inventories | Documentation, planning or comment-only changes: review diffs, links, original-item mappings, bilingual consistency and `git diff --check`; check existing Markdown structure for CHANGELOG edits | Synchronize records and commit; proofreading does not trigger a Flutter full suite, coverage or release build |
| L1: During implementation | Identify changed paths, shared contracts and direct/transitive consumers first. Run failing cases and existing tests with relevant observable behavior. Dart changes require formatting and strict analysis; structural moves require structure/architecture gates; checker changes require related Python tests. Repair and rerun failures locally first | Continue the batch once tests pass and impact is understood. Avoid mirrored tests for every private branch and duplicate fixtures for mechanical moves |
| L2: Batch integration | At technical completion of each of R1–R3, review evidence across affected domains/consumers and combine checks for new or invalidated tests/static results. Shared contracts cover every affected consumer | Reuse valid results with unchanged inputs. If the required set already covers the whole suite, record it as a full run instead of repeating the same checks under another name |
| L3: Final candidate | After R1–R3 technical completion and final documents/release assets are ready, freeze candidate inputs. Run `flutter test --no-pub --coverage`, strict analysis, formatting, structure/architecture, Python, version/Git-dependency and other existing gates; complete CLI, SDK, platform and performance matrices | Bind tests, coverage, builds and manual/performance results to actual candidate inputs. Complete the original plan only when no required evidence is missing |

An early or additional local full run requires one of these conditions:

1. A material change to shared initialization, storage coordination, request primitives, toolchain or dependencies has impact that cannot be bounded by consumer inventories and targeted tests. Record the change, evidence gap and expanded checks first.
2. Batch regression finds cross-domain failures whose impact remains unclear after local repairs. Combine repairs with the same cause before expanding verification; do not rerun everything after each assertion fix.
3. Relevant production code, tests, validation scripts, dependencies or runtime assets change after L3 and invalidate final evidence. Verify repairs with targeted tests, stabilize the candidate again, then renew the affected final gates. The old full run remains historical evidence, not a pass for new inputs.

Passing checks with unchanged relevant inputs are not repeated because time passed, a commit ID changed or a report was generated. Full-suite/coverage evidence must identify actual tested inputs; historical results quoted by documentation commits remain historical. Required CI evidence for matching source/inputs, platform and toolchain can be reused without an equivalent additional local run.

Schedule release builds per delivery platform/toolchain after the candidate stabilizes. Native plugin, build-script or packaging changes that require build diagnosis can trigger an earlier build of the affected platform only. CHANGELOG is a packaged asset: freeze it before final packaging; a documentation commit does not turn an old binary into a new package. Run Flutter tests and Windows builds serially, confirming actual process termination before starting the next operation.

### 11.5 Commits and evidence maintenance

Keep commits logically reviewable. A batch may contain multiple commits; commit count and full-run count are independent. Before each commit, synchronize CHANGELOG and the six bilingual progress, acceptance and project_structure documents using short summaries and shared evidence references. Maintain one detailed batch report instead of copying long verification narratives.

The verification record identifies batch/original items, source commit and necessary working-tree differences, relevant inputs, SDK/platform/build mode, command, result and evidence path. Reuse existing scripts. Commit-bound artifacts and helpers stay read-only and are neither re-executed nor rewritten; new verification uses a new output location and preserves previous failures/skips.

This update changes the execution plan only, not code, the 52 statuses or the paused original goal. Subsequent implementation follows these batches; completion still requires all original exit criteria.
