import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

/// Interactive root navigation; business services must use explicit actions.
final appNavigation = _AppNavigation();

class _PendingNavigation {
  _PendingNavigation({required this.action, this.isActive, this.onError});

  final FutureOr<void> Function() action;
  final bool Function()? isActive;
  final void Function(Object error, StackTrace stack)? onError;
}

class _AppNavigation {
  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? _mainNavigatorKey;

  GlobalKey<NavigatorState>? get mainNavigatorKey => _mainNavigatorKey;

  set mainNavigatorKey(GlobalKey<NavigatorState>? value) {
    _mainNavigatorKey = value;
    _schedulePendingFlush();
  }

  int _authLockCount = 0;

  bool get isAuthActive => _authLockCount > 0;

  bool get isReadyForNavigation =>
      !isAuthActive && _mainNavigatorKey?.currentContext != null;

  _PendingNavigation? _pendingNavigation;

  bool _flushScheduled = false;

  bool _postFrameFlushScheduled = false;

  /// Marks an active authentication lock on the root navigator until the
  /// returned idempotent callback is invoked.
  VoidCallback acquireAuthLock() {
    _authLockCount++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _authLockCount--;
      _schedulePendingFlush();
    };
  }

  /// Stores a single pending navigation action (latest wins) to run in a
  /// microtask once authentication is no longer active and `mainNavigatorKey`
  /// is mounted.
  void deferUntilReady(
    FutureOr<void> Function() action, {
    bool Function()? isActive,
    void Function(Object error, StackTrace stack)? onError,
  }) {
    if (isActive?.call() == false) return;
    _pendingNavigation = _PendingNavigation(
      action: action,
      isActive: isActive,
      onError: onError,
    );
    _schedulePendingFlush();
  }

  void clearPendingNavigation() {
    _pendingNavigation = null;
  }

  void _schedulePendingFlush() {
    if (_flushScheduled ||
        _pendingNavigation == null ||
        isAuthActive ||
        _mainNavigatorKey == null) {
      return;
    }
    _flushScheduled = true;
    scheduleMicrotask(_flushPendingNavigation);
  }

  void _schedulePostFrameFlush() {
    if (_postFrameFlushScheduled || _pendingNavigation == null) return;
    _postFrameFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postFrameFlushScheduled = false;
      _schedulePendingFlush();
    });
  }

  void _flushPendingNavigation() {
    _flushScheduled = false;
    final pending = _pendingNavigation;
    if (pending == null || isAuthActive) return;
    final mainKey = _mainNavigatorKey;
    if (mainKey == null) return;
    if (mainKey.currentContext == null) {
      _schedulePostFrameFlush();
      return;
    }
    _pendingNavigation = null;
    if (pending.isActive?.call() == false) return;
    _runPendingNavigation(pending);
  }

  void _runPendingNavigation(_PendingNavigation pending) {
    unawaited(
      Future<void>.sync(pending.action).catchError((
        Object error,
        StackTrace stack,
      ) {
        final onError = pending.onError;
        if (onError != null) {
          try {
            onError(error, stack);
          } catch (reportError, reportStack) {
            Zone.current.handleUncaughtError(reportError, reportStack);
          }
        } else {
          Zone.current.handleUncaughtError(error, stack);
        }
      }),
    );
  }

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
