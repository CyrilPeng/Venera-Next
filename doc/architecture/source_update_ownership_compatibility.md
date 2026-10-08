# Source update and deletion ownership compatibility

Baseline: `89ee9178d9bfe603162e2157ec8348bb5299d0ad` (2026-10-08).

## Results and dependencies

`SourceUpdateService.checkUpdates()` now returns a `SourceUpdateReport`, with immutable updates, failures and original source identities. Concurrent checks still share one Future. The mutable `lastUpdateCheck`, integer result and service/page singletons have no remaining callers and are removed. The registry's available-update map remains a notification snapshot; it is no longer a command receipt.

Each application owns its service, borrowing the installation queue's manager and repositories. The CLI acquires a service only for its update command and closes it before core release. Default dependency capture borrows an existing manager once; unused service shutdown does not create a manager. An acquired service rejects a changed data directory. The CLI adapter uses the public business entry point and retains the existing command, JSON and exit-code protocol. `finishHeadlessRuntime` still attempts close-core, binding disposal and persistence in that order; a source cleanup failure prevents unsafe core release and is reported by that close phase.

Checks still reject repository revision changes. A report update validates that particular source instance, origin kind/ID/URL and repository ID/URL, rather than requiring the entire check's revision to remain unchanged. Consequently the first successful update does not invalidate a second source merely by publishing its own configuration. Each update still reloads its repository catalog and downloads the selected script with the original URL resolution, version comparison and transport rules.

## Cancellation, mutation and presentation

| Boundary | Preserved behavior and ownership change |
|---|---|
| Download cancellation | Cancelling the current key releases its slot immediately. UI cancellation additionally supplies its exact token; an old route cannot cancel the replacement request. Retired requests remain in the original service drain. |
| Mutation admission | Validation still runs in the existing manager queue. After the accepted mutation starts, cancellation does not turn a real mutation/recovery failure into `cancelled`. No mutation is replayed automatically. |
| Client cleanup | The owned-Dio close and native-idle drain bodies are unchanged. Cleanup failures retain the original cause, stack and every close error, including when the request was cancelled. |
| Single update | The prompt captures its page, route, manager, service, path and token before execution; `WindowSelectionTask` registers it with the original application/window. Loading closes on mutation admission, as before. |
| Shared check | Leaving one page cancels that page's presentation, not other consumers' check. Application final close starts service cancellation alongside the selection/mount drains, before waiting for those consumers. |
| Confirmation | Update/delete dialogs retain their exact route. Covered or frozen callbacks cannot confirm or pop another route. Route/widget destruction completes the presentation wait even when Navigator disposal does not complete `push()`'s Future. Failed route removal retains task cleanup diagnostics. |
| Batch | Each next source requires current admission. Cancel stops later sources and cancels the current download, while an already admitted mutation still finishes. Ordinary network failures permit the next item; uncertain mutation or client cleanup failures stop the batch. |
| Delete | Confirmation and accepted deletion belong to the original manager and window/application. Optional path validation is the only change to the manager's uninstall body; its transaction, rollback and recovery logic are retained. Duplicate confirmation is rejected; incomplete recovery blocks replay through that page's retained action. Refresh calls the captured runtime callback. |

The source editor, setting callback, login and remaining source-page bodies are unchanged. Public JS assets, source/storage formats, source installation, normalization, persistence admission, window/selection primitives and CLI output/shutdown protocol bodies are retained. No new business task queue or storage transaction is introduced.

## Evidence and remaining scope

The corrected baseline fixture reproduces five issues: a swapped mutable service yields a null-result error, a covered page receives a late notice, its application stops waiting early, local-only navigation cannot open deletion, and frozen deletion still opens confirmation. Earlier fixture scheduling/cleanup failures are kept separately. The replacement test uses explicit scope replacement and discards the old presentation; separate report tests prove that later mutable registry summaries cannot change an accepted result.

There are 33 new regressions: 31 source/service/production-page cases and two application-host cases. They use temporary source scripts, real QuickJS and JSON/SQLite transactions, controlled transport and local navigators; they do not open user data or external editors. Applied and incomplete-recovery errors, exact-token cancellation, two consecutive updates, accepted deletion, interrupted presentation and the production CLI adapter are covered. Initial compile, fixture pump/guard and external-audit mistakes are retained in the task artifacts. The first expanded run passed 1042 tests; the following structure gate identified a direct feature-implementation import. That import was corrected to the public API before final formatting, a new freeze and the full suite. No gate was weakened, and neither test timeouts nor skip lists were expanded.

Final execution totals, coverage and Windows packaging evidence are recorded in [the acceptance checklist](optimization_acceptance.en.md). Both freezes and failed/intermediate logs are retained under the `source-update-ownership` artifact prefix.

This unit does not complete the original P0–P8 plan. Remaining source-origin/account/JS UI ownership, other parser capabilities, global configuration/interfaces/lifecycles/storage and compatibility work, the complete CLI assembly matrix, declared Flutter 3.41.4, five-platform acceptance and fixed-device performance remain open. The local toolchain is Flutter 3.41.6 / Dart 3.11.4.
