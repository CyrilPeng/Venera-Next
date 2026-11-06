# Local desktop_webview_window 0.2.4 source

Source: https://github.com/venera-app/flutter_desktop_webview at commit
`7801fc582ecf5a7351632887891ecf309a7b2583`, directory
`packages/desktop_webview_window`. The fork's parent is
https://github.com/wgh136/flutter_desktop_webview; the package's original upstream
is https://github.com/MixinNetwork/flutter-plugins. The version remains 0.2.4.

## Why retain this implementation

The application uses the fork's `CreateConfiguration.proxy`, title-bar options,
navigation callbacks and Windows profile directory. The snapshot also contains
Linux WebKit/libsoup integration and Windows ARM64 loader selection.

The official pub.dev 0.4.2 archive was reviewed on 2026-11-06. Its SHA-256 is
`22f23a8b88753f39207a112791eaf42ff7cf4726432f95ceab12e222ea002d46`.
It requires Flutter >=3.44.0, while the application fixes Flutter 3.41.4, and
changes the configuration/title-bar APIs without an equivalent public proxy
parameter. Adopting it would combine this migration with an SDK and API upgrade.
The current implementation is therefore maintained inside the application.

## Retained source and licenses

Runtime Dart, Linux, macOS and Windows sources, build integration, manifest,
README, CHANGELOG and analysis options are retained. Examples, upstream test
projects and local-server scripts are omitted. The package's Apache-2.0
`LICENSE` was already tracked at the pinned commit; the previous repository-root
license lookup missed it. Preserve the original Mixin copyright.

The embedded Windows WIL `LICENSE` and `ThirdPartyNotices.txt`, `strconv.h`
license and Microsoft headers are retained. The four Windows loader/import
library files match the official NuGet archives byte for byte:

- x64: Microsoft.Web.WebView2 1.0.992.28.
- ARM64: Microsoft.Web.WebView2 1.0.3124.44.

`NATIVE_ARTIFACTS.json` records archive URLs, SHA-256 values and matching archive
entries. Their original BSD-style SDK LICENSE files, and the ARM64 SDK's NOTICE,
are retained under `licenses/`. This migration does not update either loader.

`UPSTREAM_MANIFEST.json` records canonical-LF Git blob SHA-256 values and local
checksums. Binary entries use raw bytes. Added SDK license entries identify
their separate archive origins. The inventory checks every file under `lib/`,
`linux/`, `macos/`, `windows/` and `licenses/`, including new native sources and
binaries. `WINDOWS_THIRD_PARTY_NOTICES.txt` combines the retained SDK, WIL and
strconv notices; Windows CMake bundles it beside the loader, and CI verifies
the distributed file against this source. The original license files remain.

## Local changes and validation

The existing Dart formatter normalizes retained Dart source. Windows CMake adds
the notice file to bundled libraries; native runtime sources and loaders retain
the pinned implementation. `webview_impl.dart` drops the redundant explicit
`= null` initializer of the nullable callback field; its initial value and
behavior remain null. Modified Dart files carry a maintenance notice. Application
callbacks and native channel names are unchanged.

Original README, Linux CMake and generated Microsoft headers/SDK licenses retain
their upstream whitespace. Whole-snapshot `git diff --check` reports inherited
trailing spaces; Git blob hashes verify the retained text. Application, tool,
test and workflow modifications pass the whitespace check.

For changes, update this document and local checksums, compare upstream changes,
and run strict analysis, dependency inventory tests, desktop navigation/login
regressions and affected desktop builds. Keep proxy, cookie/profile, window
creation/destruction and ARM64 artifact validation in scope.

To restore the Git source, restore the pubspec declaration, lockfile entry and
inventory repository record together, then revalidate the same behavior. The
historical fork remains available for old builds and rollback.
