# Input presentation ownership and compatibility

Baseline: `5823256a2b8e3fd38056f42de2ca5a8a603d6a98` (2026-10-08).

## Presentation and accepted confirmation

`components/input_dialog.dart` now owns input presentation and confirmation. Its two production consumers, JS UI and favorite-folder rename, import it directly; `message.dart` does not retain a forwarding export. `ContentDialog`, other message helpers and the shared task/engine infrastructure remain in their existing modules. The input content tree, images, text field, initial value, hint, regular-expression validation, theme capture and button appearance retain their existing rules. The legacy `cancelText` argument remains accepted without adding a new button.

Input presentation and each accepted Dart confirmation use existing `WindowSelectionTask` registrations. Registration and busy state precede arbitrary confirmation code. The original application/window joins accepted work after dismissal or host replacement; the display Future still describes presentation closure. Each attempt captures the submitted text once, and synchronous reentry cannot start a duplicate attempt. A covered/frozen/replaced host cannot begin confirmation or publish a late result to a newer page. The common `ContentDialog` close button also verifies its own route is current.

An accepted null result is remembered even if the dialog cannot close immediately. On return, acknowledgement closes that original dialog without repeating the completed callback. A `PersistenceFailure` with `committed` or `unknown` state also blocks replay and retains its error; `OK` only dismisses the error and does not assert that an unknown commit succeeded. Only `notCommitted` permits retrying that write. Ordinary errors and non-null validation messages remain retryable, and original exceptions/stacks are logged.

The route releases its text controller and `onClosed` callback once, including Navigator disposal before the first widget build and cancellation before route creation. A failed route removal ends the presentation waiter with the original failure while retaining the exact route for an explicit host-close retry. It does not replay the callback or remove another page. Busy input preserves the confirmation's accessible name.

## Evidence and remaining scope

The initial 13 regressions produce 11 failures on the baseline: synchronous duplicate confirmation, frozen/covered admission, late pop, replay after completed confirmation or committed failure, premature application/window completion, never-built input cleanup, covered close and missing busy semantics. The two baseline passes retain ordinary retry and mounted resource disposal. The baseline test snapshot and full logs are stored with the external task artifacts.

The final 17 new widget regressions add unknown commit state, replacement registry ownership, synchronous shutdown within a confirmation and failed-close retry. Existing real QuickJS tests still exercise synchronous input validation and its public results; their pass does not establish the remaining validator resource contract. Final frozen-source, targeted/full-suite, coverage, analysis, architecture and packaging results are recorded in the acceptance log and `input-presentation-ownership-artifact-hashes.json`.

The entire JS input adapter, favorite rename callback and engine are unchanged apart from importing the new helper. JS validation still converts an immediate non-null value, including a Future, to text. Async Dart confirmation still awaits its returned Future. JS rejected graphs, alias/map-key cleanup and actual validator Promise drains remain open; this change must not be described as completing them. Select/launchUrl, toast entries, the remaining confirmation helpers and favorite callback publication also retain their separate outstanding audits. Public JS, storage formats, dependency versions and CLI behavior are unchanged.

The input helper is classified as UI. Inventory: 511 files, 325 business, 154 UI, 32 pending review, 240 business entry points. Four reverse UI/pending dependency probes are rejected; the 57 feature edges and 46-file navigation SCC remain. `message.dart` remains pending review. The original 52 rows remain 24 I / 27 P / 1 U; implementation evidence is distinct from final acceptance. Complete domain boundaries, configuration, initialization, storage/recovery, source contracts, compatibility retirement, CLI/declared SDK, five-platform validation and repeated fixed-device performance measurements remain in the original plan.
