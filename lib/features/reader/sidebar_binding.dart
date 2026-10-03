import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/components/side_bar.dart';

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
  bool _disposed = false;

  void show(BuildContext context, Widget child, {double width = 400}) {
    if (_disposed || _active != null || !context.mounted || !canOpen()) return;
    final operation = _active = _SidebarOperation();
    try {
      operation.release = acquireInteraction();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!identical(_active, operation)) return;
        try {
          if (_disposed || !context.mounted || !canOpen()) {
            _finish(operation);
            return;
          }
          final navigator = Navigator.of(context);
          final route = SideBarRoute<void>(
            child,
            width: width,
            addTopPadding: false,
          );
          operation.dismiss = () {
            if (navigator.mounted && route.isActive) {
              navigator.removeRoute(route);
            }
          };
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

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final operation = _active;
    if (operation == null) return;
    // Navigator and reader listeners may still be in tree finalization.
    // Invalidate pending callbacks now; release/remove after the tree unlocks.
    _active = null;
    scheduleMicrotask(() {
      try {
        operation.dismiss?.call();
      } catch (error, stack) {
        onError(error, stack);
      } finally {
        _release(operation);
      }
    });
  }
}

class _SidebarOperation {
  VoidCallback? release;
  VoidCallback? dismiss;
}
