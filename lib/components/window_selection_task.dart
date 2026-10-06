import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import 'window_frame.dart';

class SelectionTasksScope extends InheritedWidget {
  const SelectionTasksScope({
    required this.registry,
    required super.child,
    super.key,
  });
  final SelectionTaskRegistry registry;
  @override
  bool updateShouldNotify(SelectionTasksScope oldWidget) =>
      registry != oldWidget.registry;
}

/// Binds one selection/consumer operation to the original page and window.
/// A failed cleanup retains its window callback even after the page disappears.
class WindowSelectionTask {
  WindowSelectionTask(BuildContext context)
    : _context = context,
      _route = ModalRoute.of(context),
      _navigator = Navigator.maybeOf(context, rootNavigator: true),
      _registry = context
          .getInheritedWidgetOfExactType<SelectionTasksScope>()
          ?.registry,
      _window = context.getInheritedWidgetOfExactType<WindowFrameController>() {
    operation = SelectionOperation(checkActive: checkActive);
  }

  final BuildContext _context;
  final ModalRoute<dynamic>? _route;
  final NavigatorState? _navigator;
  final WindowFrameController? _window;
  final SelectionTaskRegistry? _registry;
  void Function()? _releaseHost;
  late final SelectionOperation operation;
  final _presentations = <VoidCallback, bool Function()>{};
  Future<void>? _closingPresentations;
  bool _presentationCloseFailed = false;
  Object? _operationError;
  StackTrace? _operationStack;

  bool get active =>
      !operation.isCancelled &&
      _registry?.isClosing != true &&
      _context.mounted &&
      _context.getInheritedWidgetOfExactType<SelectionTasksScope>()?.registry ==
          _registry &&
      (_route == null || _route.isActive) &&
      _window?.isClosing != true &&
      _context
              .getInheritedWidgetOfExactType<WindowFrameController>()
              ?.addExitTask ==
          _window?.addExitTask &&
      Navigator.maybeOf(_context, rootNavigator: true) == _navigator &&
      NavigationAdmission.allows(_context);

  bool get canPresent =>
      active &&
      (_route == null ||
          _route.isCurrent ||
          _presentations.values.any((isCurrent) => isCurrent()));
  BuildContext? get presentationContext => canPresent ? _context : null;

  void checkActive() {
    if (!canPresent) throw const SelectionCancelled();
  }

  /// Called only for routes created by this task, never for another page's UI.
  VoidCallback retainPresentation(
    VoidCallback close, {
    bool Function()? isCurrent,
  }) {
    _presentations[close] = isCurrent ?? () => false;
    if (!active) cancel();
    return () => _presentations.remove(close);
  }

  void cancel() {
    operation.cancel();
    unawaited(
      _closePresentations().catchError((Object error, StackTrace stack) {
        Log.error('Selection presentation cleanup', error, stack);
      }),
    );
  }

  Future<T> run<T>(Future<T> Function(SelectionOperation) action) {
    // run defers the callback to a microtask so registration precedes arbitrary
    // native/presentation callbacks, including synchronous window-close reentry.
    final result = operation.run(action);
    _releaseHost = _registry?.retain(cancel: cancel, close: closeAndWait);
    _window?.addCloseStartListener(cancel);
    _window?.addExitTask(closeAndWait);
    _window?.trackExitTask(operation.settled);
    if (!active) cancel();
    return _finish(result, rememberFailure: true);
  }

  Future<void> closeAndWait() async {
    // A completed failed attempt is retried only by an explicit close, not by
    // cancellation or by another waiter finishing the same operation.
    if (_presentationCloseFailed) {
      _closingPresentations = null;
      _presentationCloseFailed = false;
    }
    cancel();
    await _finish(operation.closeAndWait());
  }

  Future<T> _finish<T>(Future<T> result, {bool rememberFailure = false}) async {
    Object? cause;
    StackTrace? causeStack;
    try {
      return await result;
    } catch (error, stack) {
      cause = error;
      causeStack = stack;
      if (rememberFailure) {
        _operationError = error;
        _operationStack = stack;
      }
      rethrow;
    } finally {
      try {
        await _closePresentations();
      } on SelectionCleanupFailure catch (error) {
        throw SelectionCleanupFailure(
          error.failures,
          operationError: cause ?? _operationError,
          operationStack: causeStack ?? _operationStack,
        );
      } finally {
        _detachIfReleased();
      }
    }
  }

  void _detachIfReleased() {
    _window?.removeCloseStartListener(cancel);
    if (!operation.hasPendingCleanup && _presentations.isEmpty) {
      _window?.removeExitTask(closeAndWait);
      _releaseHost?.call();
      _releaseHost = null;
    }
  }

  Future<void> _closePresentations() {
    final previous = _closingPresentations;
    if (previous != null) return previous;
    // Page disposal can run while Navigator is locked. Retain route identity
    // and defer removals only until the synchronous navigation finishes.
    final pending = Future<void>.microtask(() {
      final failures = <({Object error, StackTrace stack})>[];
      for (final close in _presentations.keys.toList()) {
        try {
          close();
          _presentations.remove(close);
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
      }
      if (failures.isNotEmpty) {
        _presentationCloseFailed = true;
        throw SelectionCleanupFailure(failures);
      }
    });
    late final Future<void> result;
    result = pending.then((_) {
      if (identical(_closingPresentations, result)) {
        _closingPresentations = null;
      }
    });
    _closingPresentations = result;
    return result;
  }
}
