import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';

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
    final owner = WindowSelectionTask(context);
    if (!owner.active) return null;
    final originalNavigator = Navigator.maybeOf(context);
    final operation = _active = _SidebarOperation(owner);
    final handle = ReaderSidebarHandle._(
      () =>
          identical(_active, operation) &&
          owner.active &&
          Navigator.maybeOf(context) == originalNavigator &&
          operation.isCurrent?.call() == true &&
          parentRoute?.isActive != false &&
          NavigationAdmission.allows(context) &&
          canShow(),
      () => _close(operation),
    );
    try {
      owner.retainPresentation(
        () => _closePresentation(operation),
        isCurrent: () => operation.isCurrent?.call() == true,
      );
      // Register before acquisition: pausing can synchronously close the host.
      // The actual operation remains alive until its original route completes.
      unawaited(
        owner
            .run<void>((_) => operation.finished.future)
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                if (error is! SelectionCancelled) {
                  Log.error('Reader sidebar lifetime', error, stack);
                }
              },
            ),
      );
      operation.release = acquireInteraction();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!identical(_active, operation)) return;
        try {
          if (_disposed ||
              !owner.canPresent ||
              Navigator.maybeOf(context) != originalNavigator ||
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
            isOwnerActive: () => handle.isCurrent,
            // Navigator disposal can precede the first page build. Release
            // the borrowed interaction after synchronous tree finalization.
            onDispose: () => scheduleMicrotask(() => _finish(operation)),
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
    if (identical(_active, operation)) _active = null;
    operation.complete();
  }

  void _closePresentation(_SidebarOperation operation) {
    if (identical(_active, operation)) _active = null;
    _retiring.add(operation);
    var removed = false;
    try {
      operation.dismiss?.call();
      removed = true;
      operation.complete();
    } catch (error, stack) {
      // End presentation waiting, but leave the route registered for a later
      // explicit close. The original failure also remains with its host.
      operation.fail(error, stack);
      onError(error, stack);
      rethrow;
    } finally {
      _release(operation);
      if (removed) _retiring.remove(operation);
    }
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
    final retiring = _retiring.toList();
    final operation = _active;
    if (operation != null) _close(operation);
    for (final pending in retiring) {
      _close(pending);
    }
  }

  void _close(_SidebarOperation operation) {
    if (!identical(_active, operation) && !_retiring.contains(operation)) {
      return;
    }
    // Navigator and reader listeners may still be in tree finalization.
    // Invalidate pending callbacks now; release/remove after the tree unlocks.
    if (identical(_active, operation)) _active = null;
    _retiring.add(operation);
    if (operation.closing != null) return;
    final closing = operation.closing = operation.owner.closeAndWait();
    unawaited(
      closing.then<void>(
        (_) {
          operation.closing = null;
          _retiring.remove(operation);
        },
        onError: (Object error, StackTrace stack) {
          operation.closing = null;
          Log.error('Reader sidebar close', error, stack);
        },
      ),
    );
  }

  void dispose() {
    _disposed = true;
    // Repeated disposal may retry an earlier failed route removal. Completed
    // routes and borrowed releases have already detached and are not replayed.
    close();
  }
}

class _SidebarOperation {
  _SidebarOperation(this.owner) {
    // Cancellation before the deferred run can leave this future unawaited.
    finished.future.ignore();
  }

  final WindowSelectionTask owner;
  final finished = Completer<void>();
  Future<void>? closing;
  VoidCallback? release;
  VoidCallback? dismiss;
  bool Function()? isCurrent;

  void complete() {
    if (!finished.isCompleted) finished.complete();
  }

  void fail(Object error, StackTrace stack) {
    if (!finished.isCompleted) finished.completeError(error, stack);
  }
}

/// A callback from an old sidebar cannot act on or dismiss a newer operation.
class ReaderSidebarHandle {
  const ReaderSidebarHandle._(this._isCurrent, this._close);
  final bool Function() _isCurrent;
  final VoidCallback _close;
  bool get isCurrent => _isCurrent();
  void close() => _close();
}
