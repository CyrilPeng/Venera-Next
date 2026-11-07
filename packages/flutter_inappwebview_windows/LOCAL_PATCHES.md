# Local flutter_inappwebview_windows 0.7.0-beta.3

Official source: https://github.com/pichillilorenzo/flutter_inappwebview at
`0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676`, package
`flutter_inappwebview_windows`. VeneraNext maintainers own this platform exception.
The original Apache-2.0 LICENSE, copyright, Windows sources and Dart API remain.

The official stable main package 6.1.5 lacks `onBrowserProcessExited`. The selected
official commit is the common ancestor of the previous fork and current upstream
`17527cae5a3371c1e87f9c1df4281a7710debf28`. It provides the required event and
the existing coordinated API without introducing the newer Linux implementation.
The full difference from the previous fork `3ef899b3db57c911b080979f1392253b835f98ab`
is two Windows files, five insertions and two deletions.

## Necessary changes

- `windows/in_app_webview/in_app_webview_manager.h`: `graphics_context_` belongs
  to each manager instance, rather than a shared static unique pointer.
- `windows/in_app_webview/in_app_webview_manager.cpp`: initialize that instance
  pointer and release it after the manager's WebViews have been cleared.
- `pubspec.yaml`: resolve the platform interface from the same official full SHA
  instead of a sibling path, since only the Windows package is retained locally;
  mark the application-maintained package `publish_to: none`.
- Dart source formatting uses the project formatter. The upstream package's
  analyzer policy remains in its own `analysis_options.yaml`; spell its intended
  constant-name lint exception with the current boolean syntax.
- `lib/src/in_app_webview/in_app_webview.dart`: remove an unused local settings
  map for pull-to-refresh, which Windows never sends to its platform view.

`UPSTREAM_MANIFEST.json` records canonical upstream and local file checksums,
including Dart, Windows native code, LICENSE and the manifest. Examples, Git
metadata and build outputs are omitted. No shared Pub cache is modified.

## Validation and exit

Require strict application analysis, dependency solver and source checks, the
existing WebView authentication/session tests, and a Windows build of the new
package. Multiwindow close/recreate, proxy, Cookie and login behavior remain the
native acceptance scenarios. Preserve the original release sources for rollback.

Remove this local override when an official stable release or full commit
contains the instance ownership fix and passes the same acceptance. Switch the
main package and all platform packages together and update the complete lock and
source inventory; version numbers alone do not establish source equivalence.
