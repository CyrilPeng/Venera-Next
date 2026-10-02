# Architecture optimization acceptance inventory

Audit baseline: `99e607d`, 2026-10-02. The worktree includes pre-existing user changes; results describe that worktree, not HEAD alone. The original scope remains intact. This is an execution index, not a completion claim.

Status: I = implementation evidence inspected (still subject to overall acceptance); P = partial; O = code shows unfinished work; U = insufficient verification. I does not complete a phase. Short filenames refer to this directory or `.github/scripts/`; other paths are repository-relative.

Initial audit evidence (see the execution record for newer stage results): 986 Windows Flutter tests passed; analyzer has no errors/warnings and 23 infos; LCOV covers 13,988/31,156 lines (44.90%). This is the latest local `coverage/lcov.info`, not performance evidence or proof of complete behavior. The architecture report enforces 36 business entries. The aggregate SCC remains comic_details/favorites/history/local_comics/reader/search/sync and includes UI; it does not prove business cycles eliminated.

| Plan item | Status | Requirement | Inspected evidence | Remaining action/acceptance |
|---|---|---|---|---|
| P0.1 | I | Baseline and user-change isolation | `optimization_progress.zh.md` | Keep baseline 550fcff and selective staging of user changes. |
| P0.2 | I | Analyzer scope | `analysis_options.yaml` | Only build artifacts are excluded; source analysis remains enabled. |
| P0.3 | P | Tests and coverage | `output/directory-reference-full.log; coverage/lcov.info` | 986 Windows tests passed; other platforms and all script skip ownership still need acceptance. |
| P0.4 | P | Dependency reporting and exceptions | `dependency_baseline.json; check_architecture_dependencies.py` | 36 entries enforced; extend coverage to remaining services and audit business cycles. |
| P0.5 | U | Device performance baseline | `optimization_progress.zh.md: 性能基线与平台补验` | Measure six scenarios on fixed devices/data/build mode with at least three repetitions. |
| P1.1 | I | Channel removal | `git ls-files lib/foundation/channel.dart` | No longer tracked; rationale is retained in the execution record. |
| P1.2 | I | Component barrel removal | `git ls-files lib/components/components.dart` | No longer tracked; used components remain. |
| P1.3 | U | Complete reachability candidate classification | `optimization_plan.zh.md P1.3` | Produce the dynamic-entry/test/compatibility/unresolved candidate inventory. |
| P1.4 | U | Tracked temporary artifact audit | `git status --short` | User changes are preserved; finish the tracked-artifact inventory. |
| P1.5 | P | Dependency usage audit | `tool/check_git_dependencies.dart` | Git declaration/lock checks pass but do not prove production use of every package. |
| P2.1 | P | Business/UI entries | `dependency_baseline.json; lib/features/comic_source/comic_source_api.dart` | Finish remaining local/sync/WebDAV aggregate dependencies. |
| P2.2 | I | Source update service | `lib/features/comic_source/source_update_service.dart` | Service exists and is used; global dependencies/error translation remain P4/P7 work. |
| P2.3 | P | Page and CLI adapters | `lib/app_runtime/headless.dart; lib/app_runtime/headless_sync_command.dart` | Sync/source/subscription adapters, argument preflight and controlled Dart subprocess protocols are tested. Real-service composition, indirect UI dependencies and full Flutter headless-app acceptance remain open. |
| P2.4 | I | Local reading target and routing | `lib/features/local_comics/local_reading.dart; lib/routing/local_reading.dart` | Model navigation moved out; retain chapter/history regressions. |
| P2.5 | P | Cross-domain contract ownership | `lib/features/reader/chapter_image_loader.dart; lib/features/sync/data_sync.dart` | Sync participants and some source/local managers remain directly coupled. |
| P3.1 | I | Reader setting rules | `lib/foundation/reader_preferences.dart` | Defaults/ranges are centralized; preserve legacy semantics in further changes. |
| P3.2 | I | Immutable settings resolution | `lib/foundation/reader_settings.dart; test/foundation/reader_settings_snapshot_test.dart` | Snapshot/override tests exist; this does not accept all settings. |
| P3.3 | P | Typed storage and consumers | `lib/foundation/reader_preference_store.dart; lib/features/settings/reader.dart` | Reader consumers migrated; audit all consumers and integration with user changes. |
| P3.4 | P | Invalid values and round-trip compatibility | `test/foundation/reader_preference_store_test.dart; test/foundation/sync_configuration_test.dart` | Complete legacy round-trip/unknown-field/all-import-path matrix. |
| P3.5 | P | Other configuration/gates | `lib/foundation/application_configuration.dart; lib/features/webdav_library/webdav_library_settings.dart` | Network/appearance/data-sync/WebDAV snapshots exist; WebDAV settings storage is injectable; app_runtime owns assembly and six business entries are gated. Continue all-consumer configuration acceptance. |
| P4.1 | I | Shared initialization and failure | `lib/foundation/init.dart; test/foundation/init_test.dart` | State machine and explicit retry are implemented. |
| P4.2 | P | Startup dependency audit | `lib/app_runtime/bootstrap_core.dart` | Critical/optional ordering is explicit; audit all ensureInit callers and failure resources. |
| P4.3 | I | Startup mode separation | `lib/app_runtime/core_bootstrap.dart; lib/app_runtime/interactive_bindings.dart; lib/app_runtime/headless_bindings.dart` | Assembly is separated; real CLI smoke acceptance remains P0/P8. |
| P4.4 | P | Dependencies and start/dispose | `lib/features/sync/data_sync.dart; lib/features/webdav_library/webdav_library_source.dart` | DataSync has start/dispose; WebDAV is instance-owned and disposed with the mounted app. Other managers/startup-failure resources remain. |
| P4.5 | P | Reader request ownership | `lib/network/request_scope.dart; lib/features/reader/chapter_loader.dart; lib/features/reader/image_precache.dart` | Session/shared-request regressions exist; finish all source requests and device lifecycle acceptance. |
| P4.6 | P | Cancel/dispose/commit semantics | `lib/features/local_comics/local_import_lifecycle.dart; lib/features/reader/reader_session.dart` | Normal window exit is coordinated; background/OS termination and cross-store rollback remain. |
| P4.7 | O | Remove global State lookup | `lib/features/reader/comic_image.dart:358` | Still calls GlobalState.find<ReaderGestureDetectorState>; replace with an explicit interaction contract. |
| P5.1 | I | Reading position model | `lib/features/reader/image_position.dart; lib/features/reader/chapters.dart` | Models and position/group regressions exist. |
| P5.2 | I | Page/chapter policies | `lib/features/reader/page_layout.dart; test/features/reader/page_navigation_test.dart` | Policies extracted; final combined seven-mode acceptance remains separate. |
| P5.3 | P | Controller and immutable inputs | `lib/features/reader/reader_controller.dart; lib/features/reader/images.dart:79` | Still writes reader.localPageOrderChecked/imageViewController; remove concrete State dependence. |
| P5.4 | I | Chapter access injection | `lib/features/reader/chapter_image_loader.dart; test/features/reader/chapter_image_loader_test.dart` | Local-first/online-fallback adapters and regressions exist. |
| P5.5 | P | Reader views and viewport | `lib/features/reader/gallery_view.dart; lib/features/reader/continuous_view.dart; lib/features/reader/reader_viewport.dart` | Views split; ReaderImages still holds ReaderState. Finish host contracts and revalidate modes. |
| P5.6 | P | Reader shell and menus | `lib/features/reader/scaffold.dart; lib/features/reader/progress_bar.dart` | Scaffold is 914 lines with user changes; continue responsibility separation while preserving keyboard/accessibility. |
| P5.7 | P | Reader session and platform effects | `lib/features/reader/reader_session.dart; lib/features/reader/orientation_controller.dart; lib/features/reader/volume_controller.dart` | Controllers exist; real orientation/volume/brightness/background acceptance is missing. |
| P6.1 | I | Models and repositories | `lib/features/local_comics/local_repository.dart; lib/features/history/history_repository.dart; lib/features/favorites/favorites_repository.dart` | Core SQL is in repositories; maintain this boundary for new SQL. |
| P6.2 | P | Favorite business responsibilities | `lib/features/favorites/read_later_service.dart; lib/features/favorites/favorite_updates_service.dart; lib/features/favorites/favorites_manager.dart` | Read-later/update services split; global manager dependencies/lifecycle remain. |
| P6.3 | P | Local storage/import/download | `lib/features/local_comics/local.dart; lib/features/local_comics/local_deletion_paths.dart` | Queue/repository/migration split; symlinks, deletion rollback and unguarded direct writers remain. |
| P6.4 | I | WebDAV instantiation and separation | `lib/features/webdav_library/webdav_library_synchronizer.dart; lib/features/webdav_library/webdav_library_snapshot_store.dart; lib/features/webdav_library/webdav_library_source.dart` | Config/discovery/snapshots/cache/sync/source adaptation are separated with injected instances and path/incremental-sync/cancellation regressions. Overall P6 data/performance/platform exit conditions still apply. |
| P6.5 | P | Application sync responsibilities | `lib/features/sync/data_sync_controller.dart; lib/app_runtime/data_sync.dart` | Archive/window/transfer/participant separated; production singleton and test hooks removed. Configuration-failure cleanup and in-flight disposal still need final acceptance. |
| P6.6 | P | Narrow sync contracts | `lib/features/sync/data_sync_controller.dart; test/features/sync/data_sync_schedule_test.dart` | Explicit controller ports/application callbacks; legacy entry retired. Final restart/no-echo matrix and protocol-failure boundaries remain. |
| P6.7 | P | Atomicity constraints | `lib/foundation/sqlite_transaction.dart; lib/foundation/directory_replacement.dart; lib/features/local_comics/local.dart` | Transaction/recovery utilities exist; deletion can still partially commit across filesystem/database. |
| P7.1 | I | Split parser by capability | `lib/features/comic_source/parser.dart; source_*_parser.dart; source_parser_context.dart` | Account, explore, category, search, favorites, images, comments, comic and metadata are separate with immutable source identity. Full capability/error matrices remain under P7.2/P7.5. |
| P7.2 | P | JS and minimal-source compatibility | `source_capability_matrix.en.md; test/features/comic_source/source_capabilities_test.dart` | Real QuickJS covers login/re-login, cursors, legacy/current categories and capability identity. Valid dynamic-function lifetime, archives/votes/metadata and full cancellation matrices remain open. |
| P7.3 | U | Repeated-flow comparison | `optimization_plan.zh.md P7.3` | Produce update/image/archive/sync/import mechanism-versus-business-difference table. |
| P7.4 | P | Extract proven common mechanisms | `lib/foundation/throttled_task_runner.dart; lib/network/request_scope.dart` | Reuse existing primitives; use P7.3 to justify new abstractions and remove duplicates. |
| P7.5 | O | Structured errors | `lib/features/comic_source/source_update_service.dart; lib/foundation/res.dart` | Update service still throws translated strings; define failure/cancel/unsupported and Res adapter boundaries. |
| P7.6 | P | Reuse technical rules | `lib/features/comic_source/parser.dart:23; lib/features/comic_storage/archive_metadata.dart` | Metadata/file rules are shared; version/date rules still need usage/compatibility review. |
| P8.1 | P | Retire compatibility/test switches | `lib/features/local_comics/local.dart:52; lib/app_runtime/data_sync.dart` | Sync singleton/reset/debug removed. Other domains retain reset/debug; aggregate exports await further review. |
| P8.2 | O | Restore lints and boundary types | `analysis_options.yaml` | collection_methods_unrelated_type and use_build_context_synchronously remain false. |
| P8.3 | P | CI and coverage trend | `.github/workflows/analyze.yml` | Checks/coverage upload exist; unregistered services remain outside entry enforcement. |
| P8.4 | U | Final platform/performance acceptance | `.github/workflows/build.yml; optimization_progress.zh.md` | Workflow existence is not a successful run; collect five-platform results and device remeasurement. |
| P8.5 | P | Final removal/debt report | `optimization_acceptance.zh.md` | This inventory establishes tracking; re-audit each item instead of using test counts as acceptance. |

## Overall acceptance (original plan section 9)

| Item | Current assessment | Required evidence |
|---|---|---|
| 9.1 Business without UI/State dependencies | Incomplete | Extend enforced entries and remove ReaderImages/global gesture State dependencies and reverse UI references |
| 9.2 Business cycles and CI | Unproven | Inspect transitive dependencies of all key services and classify UI cycles; 36 passing entries are not whole-project proof |
| 9.3 Reader controllers/policies | Partial | Finish P5.3/P5.5/P5.6 and combined seven-mode tests including existing user changes |
| 9.4 Dependencies/lifecycle | Partial | WebDAV isolation regressions exist; continue DataSync participant injection, other production reset retirement and the full failure/disposal matrix |
| 9.5 Removals/compatibility | Incomplete | P1 candidate decisions, actual caller audit of forwarding layers and P8.1 retirement record |
| 9.6 Data/JS/CLI/platform compatibility | Unproven | Legacy fixtures, synthetic sources, real CLI subprocess and five-platform results with explicit limitations/skips |
| 9.7 Performance/coverage | Unproven | Fixed-device before/after measurements; 44.90% is a line-coverage snapshot, not a passing threshold |
| 9.8 Documentation matches code | In progress | Update inventory/structure/gates/changelog each stage and remove stale statements at final review |

## Commands and deliverables

- Latest `flutter test --no-pub --coverage --reporter expanded`: `output/directory-reference-full.log`, 986 passed. This documentation-only audit did not repeat it.
- Latest `flutter analyze --no-pub --no-fatal-infos`: `output/directory-reference-analyze.log`, 23 infos and no errors/warnings. CI also explicitly uses `--fatal-warnings`.
- This audit ran `python .github/scripts/check_structure_imports.py --print-feature-dependencies` and `python .github/scripts/check_architecture_dependencies.py --report`; both passed within the stated scope.
- Architecture unit tests, Git dependencies and changed-file formatting were checked for preceding code commits. The 12 architecture tests do not replace the full CI command `python -m unittest discover -s .github/scripts/tests -p 'test_*.py'`; final acceptance must run the full set and explain skips.
- `.github/workflows/analyze.yml` configures structure/architecture, full Python tests, locked dependencies, changed-file formatting, analysis, Flutter tests and coverage summary/upload. Configuration is not proof of a successful current remote run. No new PR or verified five-platform run was obtained.
- No committed fixed-device measurements, P7 flow-comparison table or complete dead-code decision inventory was located. These remain required deliverables, not waived technical debt.
- Section 6's 20 commit units map as follows: 01–02→P0; 03→P1; 04–06→P2; 07–08→P3; 09–11→P4; 12–14→P5; 15–18→P6 (18 also P3); 19→P7; 20→P8. Commit count is not acceptance.
- Section 7 logic/fixture/failure/widget/core-integration categories have test evidence that must evolve with remaining changes. Real CLI, five-platform and performance acceptance remain outstanding. Section 8 format/backup/atomicity/cross-version constraints remain mandatory.

## Execution order

1. P6.4 config/discovery/snapshot/sync/source separation has implementation and regression evidence. Maintain legacy-cache/path/incremental-sync compatibility and revisit during overall platform/performance acceptance. Main execution now moves to P6.5/P6.6.
2. Finish P6.5/P6.6 scheduling/transport/data-participant boundaries. Complete explicit acceptance of local deletion recovery and symlink policy instead of adding isolated exceptions indefinitely.
3. Finish P5 host State/gesture/shell contracts while preserving/integrating user changes; close P4 lifecycle/test-injection gaps alongside them.
4. Execute all P7 capability extraction, protocol regressions, mechanism comparison and structured errors. Do not mechanically split files while retaining implicit shared state.
5. P8 compatibility retirement, lint restoration and complete script/CLI/platform/performance checks. Only complete the goal after every inventory and section-9 requirement is proven.

This audit preserves the original objective and waives nothing. Complete P0 measurements, P1 classification and remaining P3 settings at the relevant steps. Unavailable platforms remain unverified; Windows tests do not replace them.
