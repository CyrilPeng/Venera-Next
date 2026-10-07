import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/foundation/navigation_admission.dart';

/// Owns the shell's pending/open sidebar and its temporary interaction pause.
class ReaderSidebarBinding {
  ReaderSidebarBinding({
    required this.canOpen,
    required this.acquireInteraction,
    required this.onError,
  });

  final bool Function() canOpen;
  final VoidCallback Function() acquireInteraction;
  final void Function(Object, StackTrace) onError;
  _SidebarOperation? _active;
  final _retiring = <_SidebarOperation>{};
  bool _disposed = false;

  ReaderSidebarHandle? show(
    BuildContext context,
    Widget child, {
    double width = 400,
    bool showBarrier = true,
    bool Function()? isRequestCurrent,
  }) {
    bool canShow() => canOpen() && (isRequestCurrent?.call() ?? true);
    if (_disposed ||
        _active != null ||
        !NavigationAdmission.allows(context) ||
        !canShow()) {
      return null;
    }
    final parentRoute = ModalRoute.of(context);
    // Replacing our own route can be queued before its deferred removal, but
    // a genuinely unrelated covering route must not receive this navigation.
    if (parentRoute?.isCurrent == false &&
        !_retiring.any((operation) => operation.isCurrent?.call() == true)) {
      return null;
    }
    final operation = _active = _SidebarOperation();
    final handle = ReaderSidebarHandle._(
      () =>
          identical(_active, operation) &&
          operation.isCurrent?.call() == true &&
          parentRoute?.isActive != false &&
          NavigationAdmission.allows(context) &&
          canShow(),
      () => _close(operation),
    );
    try {
      operation.release = acquireInteraction();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!identical(_active, operation)) return;
        try {
          if (_disposed ||
              parentRoute?.isCurrent == false ||
              !NavigationAdmission.allows(context) ||
              !canShow()) {
            _finish(operation);
            return;
          }
          final navigator = Navigator.of(context);
          final route = SideBarRoute<void>(
            child,
            width: width,
            showBarrier: showBarrier,
            addTopPadding: false,
            transitionDuration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 300),
          );
          operation.dismiss = () {
            if (navigator.mounted && route.isActive) {
              navigator.removeRoute(route);
            }
          };
          operation.isCurrent = () => route.isCurrent;
          navigator
              .push(route)
              .then(
                (_) => _finish(operation),
                onError: (Object error, StackTrace stack) {
                  _finish(operation);
                  onError(error, stack);
                },
              );
        } catch (error, stack) {
          _finish(operation);
          onError(error, stack);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } catch (error, stack) {
      _finish(operation);
      onError(error, stack);
    }
    return handle;
  }

  void _finish(_SidebarOperation operation) {
    if (!identical(_active, operation)) return;
    _active = null;
    _release(operation);
  }

  void _release(_SidebarOperation operation) {
    final release = operation.release;
    operation.release = null;
    try {
      release?.call();
    } catch (error, stack) {
      onError(error, stack);
    }
  }

  /// Retire the current request/route when its reader input is replaced.
  /// The binding remains available to open a sidebar for the new input.
  void close() {
    final operation = _active;
    if (operation == null) return;
    _close(operation);
  }

  void _close(_SidebarOperation operation) {
    if (!identical(_active, operation)) return;
    // Navigator and reader listeners may still be in tree finalization.
    // Invalidate pending callbacks now; release/remove after the tree unlocks.
    _active = null;
    _retiring.add(operation);
    scheduleMicrotask(() {
      try {
        operation.dismiss?.call();
      } catch (error, stack) {
        onError(error, stack);
      } finally {
        _retiring.remove(operation);
        _release(operation);
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    close();
  }
}

class _SidebarOperation {
  VoidCallback? release;
  VoidCallback? dismiss;
  bool Function()? isCurrent;
}

/// A callback from an old sidebar cannot act on or dismiss a newer operation.
class ReaderSidebarHandle {
  const ReaderSidebarHandle._(this._isCurrent, this._close);
  final bool Function() _isCurrent;
  final VoidCallback _close;
  bool get isCurrent => _isCurrent();
  void close() => _close();
}
