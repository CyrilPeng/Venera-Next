# JS UI callback ownership and compatibility

Baseline: `1a1460a2af20b01cb1a83e66f4e8649f8576df4c` (2026-10-08).

## Original engine, host and route

`JsUiMessageHandler` receives the engine that emitted the message. A runtime receives its handler through construction or one-time `bindUiMessageHandler`; another engine cannot replace that binding. Main and headless composition bind their original engine, and tests inject independent engines. The former static UI handler and its reset calls are removed. The separate, unused `JsEngine.reset()` method was also removed after checking production, test, tool and asset references. Source data bridging, HTTP/compute ownership, source reloads and the engine's completion/release/shutdown bodies are unchanged.

`JsUiApi` borrows the original mounted UI host on first presentation and retains its admission check. A disposed or replaced host cannot be adopted by the old handler. Dialog actions retain their exact dialog route and original finish callback. A covered or frozen route cannot start an action, close a newer page or receive a late error notice. Navigator disposal still completes the dialog presentation even when its push Future does not complete.

## Callback completion and loading IDs

Actions and loading cancellation reuse `invokeJsCallbackToCompletion`, `JsCallback.consume` and existing `WindowSelectionTask` registrations. An accepted call joins its original top-level Promise and releases success/rejection reference graphs. Dismissing presentation does not finish that call. The original application/window registration remains while the work settles; ordinary failure is logged with its original exception and stack, and cleanup failures retain the engine's existing diagnostics. No automatic action retry or new business queue is introduced.

The action button enters busy state before invoking user code, rejects synchronous reentry and keeps its accessible name while disabled. Loading cancellation records admission before invoking its callback, so reentry cannot invoke it twice. Numeric loading IDs and `cancelLoading` remain: programmatic completion does not invoke user cancellation, user dismissal does, and an ID can be reused after presentation closes while the old callback still drains. Old completion removes only its own entry. Creation of loading presentation occurs after task registration; an immediate programmatic completion can prevent it from appearing.

`UI.showDialog` continues to report presentation completion; callback task ownership is separate. Public `assets/init.js`, method/argument names, callback argument lists, source/storage formats and CLI output/exit protocol remain unchanged. Headless UI requests still throw `UnsupportedError` without a Navigator.

## Verification and limits

Seven corrected baseline regressions reproduce covered-route dismissal/notices, premature application completion for actions and loading cancellation, frozen callbacks, synchronous duplicate actions and rejected reference leakage. Initial baseline runs were interrupted because the fixture awaited a cached Future from the widget fake-async zone without pumping it. A bounded event-pumping cleanup resolved that fixture issue; the seven-failure run is the authoritative baseline. Earlier logs and fixture snapshots remain.

There are 18 new regressions, including real QuickJS resolve/reject graphs, independent runtimes, original application waits, cancellation reentry, ID reuse and accessible busy state. The synchronous input-validator contract is separately checked: a returned Future is converted to a string immediately rather than awaited as valid input. A migrated old test now explicitly rejects reusing its handler after Navigator replacement before creating a new UI handler. New native-fixture initialization and semantics-handle mistakes, and an unused test import found by strict analysis, were corrected; no skip list or test timeout was relaxed. Final totals, coverage and packaging evidence are in the acceptance record.

The input validator's synchronous conversion/error behavior and the select-dialog body are unchanged, apart from borrowing the explicit engine and original context for input. This unit does not complete their result/rejection graph, exact-route or lifetime audit. Launching external URLs, complete JS UI/source/account callback matrices, arbitrary descendant Promises and unreturned script tasks remain open. The top-level consuming callback contract does not imply those stronger guarantees.

`components/js_ui.dart` is classified as UI because it translates JS messages into presentation, interaction and resource ownership; it does not implement source business capabilities. Inventory: 510 files, 325 business, 153 UI, 32 pending review, 240 business entry points. Four reverse UI/pending dependency probes are rejected; all previous business protections, 57 feature edges and the 46-file navigation SCC remain. Classification is distinct from complete lifecycle acceptance.

The original plan still has 24 I / 27 P / 1 U. Remaining domain interfaces, configuration, initialization, storage/recovery and compatibility work, complete CLI assembly, declared Flutter 3.41.4, five-platform and fixed-device performance validation remain open. Local Flutter 3.41.6 / Dart 3.11.4 and Windows synthetic fixtures do not replace them.
