# Loading presentation and toast ownership

Baseline: `bfbb2551f0e68949da2905686ca4503b041fbb34` (2026-10-08).

## Loading cancellation and disposal

Loading presentation now reuses ResourceDialogRoute. Its disposal callback runs even when the Navigator disappears before the first widget build. The original barrierDismissible setting, DialogRoute theme defaults, progress content, button label and cancelOnDismiss behavior remain. Programmatic completion does not invoke user cancellation. Explicit Cancel does; implicit dismissal does only when cancelOnDismiss is true.

The first loading build borrows a WindowSelectionTask as an admission snapshot. Cancel requires its original current route and original application/window admission; a frozen, covered, replaced or disposed host cannot invoke a retained button. This guard does not itself register or join arbitrary business work. Existing caller tasks retain that responsibility, and the generic onCancel/onClosed callbacks remain synchronous.

Cancellation records invocation before calling arbitrary code. An in-progress button callback cannot reenter and prematurely close the same route. After the callback has run, a failed removal can be explicitly retried with Cancel or the controller without invoking cancellation again. LoadingDialogController's original failed-close reset remains. Progress/message updates cannot call a disposed builder. DialogResourceScope also reaches super.dispose when its callback throws.

JS loading retains its existing original-engine callback and application/window task. A failed controller removal now ends display waiting with that failure, while the task still joins an already accepted cancellation invocation. The original route remains registered for explicit host-close retry; the callback is not replayed. Result/rejection references use the existing engine completion bridge. Release and operation errors remain distinguishable through the task's original diagnostics. Numeric loading IDs, programmatic cancelLoading and independent callback completion are unchanged.

## Overlay entries and boundaries

OverlayWidget owns one initial content entry for its lifetime and disposes it on removal. The builder still reads the current widget child, preserving replacement content. Toast entries are detached and disposed when the last toast is removed; timers and a retired entry cannot remove a later notice. The toast rendering tree, spacing, text styles, three-line truncation and expiry defaults are unchanged. Zero-duration expiry is verified before the first toast frame.

A full read of message.dart identifies UI rendering, interaction admission, routes, overlay resources and injected confirmation/cancellation callbacks. It implements no source, storage or import capability. It is classified as UI after that review; this is separate from completing all its remaining confirmation/error lifecycles. Inventory is 512 files: 325 business, 156 UI, 31 pending review, with 240 business entry points. Existing protections, 57 feature edges and the 46-file SCC remain; six reverse UI/pending probes reject.

## Evidence and remaining scope

Seven original loading regressions fail on automatic never-built disposal, reentry and inactive-host callbacks. Four JS loading cases fail on never-built disposal and failed-removal waiting. The corrected toast baseline has three behavior passes and one ownership failure. Its original zero-duration test had not advanced the fake clock; explicit zero-time advancement corrected that fixture. Content replacement already passed and is preserved. Two intermediate cancellation refinements cover premature reentrant closure and cleanup-only retry; their failed logs remain.

There are 18 new regressions, including real QuickJS resolve/reject graphs after never-built disposal. Final targeted validation has 157 passes across loading/toast, input/selection, settings, original application/window tasks, source updates and import presentations. Two mistyped test paths in an intermediate command and one strict-analysis collection-style diagnostic were corrected; no skip or timeout was relaxed. Both source freezes and all logs remain. Seven changed paths and all 993 Dart files are frozen. Final full-suite, coverage and build results are recorded in the acceptance log and `loading-toast-ownership-artifact-hashes.json`.

Thirty protocol/infrastructure blobs are unchanged, including the JS engine, input/selection helpers, task/window infrastructure, public JS assets, dependencies, storage and CLI composition. Other JS UI regions, ordinary confirmation helpers, ContentDialog and toast/progress rendering remain. Complete arbitrary callback-release failures, generic confirmation ownership, external launch, favorite publication, archive selection and domain-wide configuration/lifecycle/storage/source/account contracts remain open. The original plan retains 24 I / 27 P / 1 U; declared Flutter 3.41.4, complete CLI, five-platform scenarios and repeated fixed-device performance acceptance are not established by local Flutter 3.41.6 / Dart 3.11.4 Windows fixtures.
