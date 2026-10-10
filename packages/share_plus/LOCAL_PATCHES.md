# Local share_plus 12.0.2 patch

Source: [share_plus 12.0.2 on pub.dev](https://pub.dev/packages/share_plus/versions/12.0.2),
from the [original package archive](https://pub.dev/api/archives/share_plus-12.0.2.tar.gz).
Archive SHA-256:
`223873d106614442ea6f20db5a038685cc5b32a2fba81cdecaefbbae0523f7fa`.
`UPSTREAM_MANIFEST.json` records SHA-256 hashes for the 36 retained original files
before local edits. The BSD-3-Clause `LICENSE` is retained unchanged.
VeneraNext maintainers own these local patches; the package version remains 12.0.2.

The package `pubspec.yaml` final blank line and unchanged macOS lines retain
their upstream whitespace. `UPSTREAM_MANIFEST.json` describes the original
source before local patches; edited native files intentionally differ.

The package retains its Dart libraries, native platform sources/configuration,
manifest, license and upstream README/CHANGELOG. Local ownership primitives,
native regression tests and these provenance records are added. Native changes
cover Android, Windows, iOS and macOS. Five of the six Dart library files match
upstream; `lib/share_plus.dart` changes only two API comments to document Android's
`share_busy` result for a concurrent native request. Apple changes are described
below. The other 156 application package lock records and SDK records remain
unchanged; `flutter pub get --offline --enforce-lockfile` succeeds with the existing
cache and the lockfile's `https://pub.dev` host.

## Windows request and COM ownership

The upstream plugin reused mutable title/text/path state and registered new
DataRequested handlers without retiring the old subscription. Local code parses
each call into an immutable payload, resolves StorageFile references before
opening the panel, and captures the payload independently of plugin lifetime.
Replacing or destroying the plugin releases its subscription. If removal fails,
the token remains owned and a second subscription is refused until cleanup can
be retried. Already-dispatched callbacks can still supply their original data.

An acknowledged panel may still be waiting for its first DataRequested when a
replacement Show fails. A callback running before Show returns takes a native
DataRequest deferral; its independent, synchronized state supplies data only after
the Show outcome chooses the new or previous immutable payload. The deferral is
completed once even if delivery fails. A callback that is still obtaining its
deferral when Show returns reads the settled choice and completes its own work.
This covers synchronous reentry and concurrent callbacks without assuming either
panel has ended. Deferred delivery errors use FailWithDisplayText, with secondary
reporting/Complete failures sent to OutputDebugString; the Future remains a Show
acknowledgment.

Failed Show keeps one live subscription serving the previous accepted payload.
Failed registration re-registers the old callback, reporting a second HRESULT if
that restoration fails. With no previous accepted request, failed Show rejects
deferred data, completes deferrals and removes the new handler (or retains its
token and cleanup failure for retry).

Factory, interop, native-file and data-setter HRESULTs are checked. Missing files
fail before acknowledgment; successful calls returning null are rejected.
StorageFile conversion uses QueryInterface. The retained upstream `vector.h`
remains in use: heap-allocated collections and ComPtr/AddRef ownership keep items,
iterables and iterators alive. No stack collection or reinterpret_cast conversion
is used. Show/removal double failures preserve both HRESULTs. DataRequest errors
call FailWithDisplayText and return the original HRESULT; secondary reporting or
destructor-cleanup failure is written to OutputDebugString.

The Future still returns unavailable after ShowShareUIForWindow succeeds. Neither
DataRequested nor TargetApplicationChosen establishes receiver-consumption
completion. Sources are not deleted by this plugin. The older Windows fallback
continues to reject file sharing.

## Android file and result ownership

Upstream cleared the shared cache before each request, reused source basenames
and let a new call replace a pending result callback. `ShareFileSession` now owns
a unique request directory and an independent subdirectory per file, preserving
same-name files both within a request and across requests. It copies inputs before
dispatch. A failure before accepted launch revokes that request's URI grants and
removes only its undelivered directory. All cleanup attempts run, with failures
attached as suppressed exceptions to the original error.

Once launch is accepted, copied URI sources remain available. Chooser completion,
a later share (including text), and process restart do not sweep them. There is
no TTL/startup deletion; Android or the user may evict cache files. This policy
does not prove when an external app finishes reading.

`ShareRequestCoordinator` rejects concurrent requests with `share_busy` while
preserving the first callback. Owner identity, a unique chooser token and activity
codes that are not reused during the process reject delayed broadcasts/results.
Activity configuration changes preserve pending ownership; permanent Activity or
engine detach releases waiting with unavailable. An accepted launch without an
Activity acknowledges only after startActivity succeeds. Native error details
retain the stack and suppressed cleanup diagnostics.

## Apple result reporting

iOS preserves `activityError` as a `share_failed` FlutterError with its original
domain and code. A cancelled activity still returns the existing cancellation
result. macOS validates arguments and the presentation view, owns one callback
per request, and waits for `didShareItems` or `didFailToShareItems`; selecting a
service alone no longer reports success. Cancelling the picker and completing
the service each release the retained delegate through one idempotent result.

These changes have been reviewed as source. Apple compilation, system service
callbacks and external receiver behavior await the corresponding Actions runner
and device validation. A service completion is not a universal guarantee that
an arbitrary recipient will never read a shared file again.

## Application consumer contract and remaining boundaries

Application-side `withShareFileSource` owns a separate directory under
`App.cachePath/shares`, validates filenames and lengths, and preserves operation
plus cleanup failures. Android's synchronous native copy allows app-owned input
staging to be removed after the platform returns; delivered plugin copies remain
separate. Windows/iOS/macOS input sources remain after dispatch, including errors,
because the platform Future does not prove they are no longer being consumed.
Pre-dispatch failures remove only the app's own staging. No application TTL or
startup sweep has been added.

File and text sharing use one application `PlatformDialogQueue`; saving uses a
separate instance. Visible origins support iPad popovers. Linux file sharing is
already unsupported and now fails at the app boundary before staging. Unknown
Windows dispatch failures conservatively retain input. Actual Apple activity-error
delivery, external-consumer cleanup and five-platform device behavior remain
unverified; these patches do not add a universal receiver-completion protocol.

## Validation

Windows configuration and commands are documented in
[`windows/tests/README.md`](windows/tests/README.md):

```powershell
cmake -S packages/share_plus/windows/tests -B <external-build-directory> -A x64 `
  -DFLUTTER_EPHEMERAL_DIR="<repository>/windows/flutter/ephemeral"
cmake --build <external-build-directory> --config Debug
ctest --test-dir <external-build-directory> -C Debug --output-on-failure
```

One CTest executable passes six regression groups using real WinRT DataPackage,
StorageFile and temporary files, fake COM event failures, and reference-counted
items. Production core and the actual plugin adapter compile with `/W4 /WX /EHsc`
and `_HAS_EXCEPTIONS=0`. Tests cover content isolation, 100 handler replacements,
callbacks surviving replacement/destruction, collection lifetime, malformed or
missing inputs, pending-panel restoration and original/double failures. The
pending-panel and synchronous reentry cases reproduce the preceding defects;
final tests also cover Show settling during concurrent GetDeferral and complete
deferrals after rejection or data failure. They do not open a share panel or
exercise an external recipient.

From the application's `android/` directory, run:

```powershell
.\gradlew.bat :share_plus:testShareOwnership
```

The actual Android project compiles native production code and passes 13 JVM
regressions for file retention, duplicate names, partial rollback, cache isolation,
error preservation, concurrent ownership, late results, owner/admission handling
and activity-code exhaustion. No extra test dependency or emulator is required.
These tests exercise production file/request primitives; Activity, URI-provider,
chooser and recipient behavior still require device acceptance.

App regression coverage lives in `test/foundation/share_file_operation_test.dart`,
`test/foundation/share_file_test.dart` and
`test/features/comic_details/share_lifecycle_test.dart`. Final application-wide
validation is recorded separately in the architecture execution/acceptance docs.
