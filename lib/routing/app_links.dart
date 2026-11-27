import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:app_links/app_links.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';

EventSubscription<Uri> createAppLinkSubscription() => EventSubscription(
  events: AppLinks().uriLinkStream,
  handle: (uri, isActive) async {
    await handleAppLink(uri, isActive: isActive);
  },
  onError: (error, stack) => Log.error('App links', error, stack),
);

Route<dynamic>? _currentTopRoute(NavigatorState navigator) {
  Route<dynamic>? top;
  navigator.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

/// Dismisses overlays pushed onto `rootNavigatorKey` (such as `Reader`,
/// sidebars, or dialogs) so a deep-linked comic opened on `mainNavigatorKey`
/// becomes visible.
///
/// Never pops or invokes `maybePop()` while `AuthPage` is active: `AuthPage`
/// intercepts `maybePop()` to call `SystemNavigator.pop()`, and popping past
/// it would bypass app lock.
///
/// Uses `maybePop()` so `PopScope` guards such as `ReaderExitGuard` run their
/// async save-and-leave flow. If the top route remains active after `maybePop`
/// and a microtask turn (e.g., async save still in flight or explicit pop
/// refusal), unwinding stops rather than looping or re-invoking `PopScope`.
Future<void> _dismissRootOverlays({bool Function()? isActive}) async {
  if (appNavigation.isAuthActive) return;
  final rootNavigator = appNavigation.rootNavigatorKey.currentState;
  if (rootNavigator == null || !rootNavigator.mounted) return;

  final attempted = <Route<dynamic>>{};
  while (rootNavigator.mounted && rootNavigator.canPop()) {
    if (isActive?.call() == false) return;
    if (appNavigation.isAuthActive) return;
    if (!NavigationAdmission.allows(rootNavigator.context)) return;

    final topBefore = _currentTopRoute(rootNavigator);
    if (topBefore == null || topBefore.isFirst || !attempted.add(topBefore)) {
      return;
    }

    final handled = await rootNavigator.maybePop();
    if (!rootNavigator.mounted ||
        isActive?.call() == false ||
        appNavigation.isAuthActive ||
        !handled) {
      return;
    }

    if (!topBefore.isActive) {
      continue;
    }

    await Future<void>.microtask(() {});
    if (!rootNavigator.mounted ||
        isActive?.call() == false ||
        appNavigation.isAuthActive) {
      return;
    }
    if (topBefore.isActive) {
      return;
    }
  }
}

Future<bool> handleAppLink(
  Uri uri, {
  bool Function()? isActive,
  Widget Function(String id, String sourceKey)? comicPageBuilder,
}) async {
  if (isActive?.call() == false) return false;
  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if (id != null) {
          if (appNavigation.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          if (isActive?.call() == false) return false;
          await _dismissRootOverlays(isActive: isActive);
          if (isActive?.call() == false) return false;
          final builder = comicPageBuilder;
          appNavigation.mainNavigatorKey?.currentContext?.to(() {
            return builder != null
                ? builder(id, source.key)
                : ComicPage(id: id, sourceKey: source.key);
          });
          return true;
        }
        return false;
      }
    }
  }
  return false;
}
