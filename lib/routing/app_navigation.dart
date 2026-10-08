import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

/// Interactive root navigation; business services must use explicit actions.
final appNavigation = _AppNavigation();

class _AppNavigation {
  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  void rootPop() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && NavigationAdmission.allows(navigator.context)) {
      navigator.maybePop();
    }
  }

  void pop() {
    final context = rootNavigatorKey.currentContext;
    if (context != null && !NavigationAdmission.allows(context)) return;
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function? handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}
