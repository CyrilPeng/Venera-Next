import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/owned_dio_client.dart';
import 'package:venera_next/network/request_scope.dart';

/// One read-only inspection and its actual completion belong to the original
/// page/window, including after supersession or disposal. This is not a save
/// operation: closing never replays selection, reading or preview generation.
class SourceInspectionTask<T> {
  SourceInspectionTask(BuildContext context)
    : _context = context,
      _route = ModalRoute.of(context),
      _registry = context
          .getInheritedWidgetOfExactType<SelectionTasksScope>()
          ?.registry,
      _window = context.getInheritedWidgetOfExactType<WindowFrameController>();

  final BuildContext _context;
  final ModalRoute<dynamic>? _route;
  final WindowFrameController? _window;
  final SelectionTaskRegistry? _registry;
  void Function()? _releaseHost;
  final _scope = RequestScope();
  Future<T>? _result;
  Future<void>? _drained;
  FileSelectionCleanupFailure? _fileFailure;
  Future<void>? _closing;
  bool _finished = false;
  bool _fileReleased = false;

  bool get sameWindow =>
      _context.mounted &&
      _context.getInheritedWidgetOfExactType<SelectionTasksScope>()?.registry ==
          _registry &&
      _context
              .getInheritedWidgetOfExactType<WindowFrameController>()
              ?.addExitTask ==
          _window?.addExitTask;

  bool get active =>
      !_scope.isCancelled &&
      sameWindow &&
      _registry?.isClosing != true &&
      _window?.isClosing != true &&
      (_route == null || _route.isCurrent) &&
      NavigationAdmission.allows(_context);

  void cancel() => _scope.cancel();

  Future<T> run(Future<T> Function(RequestScope scope) action) {
    final existing = _result;
    if (existing != null) return existing;
    final done = Completer<T>();
    _result = done.future;
    // Establish both the result and drain before callbacks can reenter close.
    _drained = done.future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (error is FileSelectionCleanupFailure) _fileFailure = error;
        if (error is DioCleanupFailure ||
            error is FileSelectionCleanupFailure) {
          Error.throwWithStackTrace(error, stack);
        }
      },
    );
    unawaited(
      _drained!.catchError((Object error, StackTrace stack) {
        Log.error('Source inspection cleanup', error, stack);
      }),
    );
    _releaseHost = _registry?.retain(cancel: cancel, close: closeAndWait);
    _window?.addCloseStartListener(cancel);
    _window?.addExitTask(closeAndWait);
    _window?.trackExitTask(_drained!);
    if (!active) cancel();
    _scope
        .runToCompletion(() => action(_scope))
        .then(
          (value) {
            _finish(retainFailure: false);
            done.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            // A cleanup failure stays on the original window's exit callback even
            // if its page or normal tracked Future was removed before close.
            _finish(
              retainFailure:
                  error is DioCleanupFailure ||
                  error is FileSelectionCleanupFailure,
            );
            done.completeError(error, stack);
          },
        );
    return done.future;
  }

  void _finish({required bool retainFailure}) {
    _finished = true;
    _window?.removeCloseStartListener(cancel);
    if (!retainFailure) _detach();
    _scope.dispose();
  }

  void _detach() {
    _window?.removeExitTask(closeAndWait);
    _releaseHost?.call();
    _releaseHost = null;
  }

  Future<void> closeAndWait() {
    final previous = _closing;
    if (previous != null) return previous;
    cancel();
    final wasRunning = !_finished;
    final done = Completer<void>();
    _closing = done.future;
    _close(wasRunning: wasRunning).then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        if (error is FileSelectionCleanupFailure && !_fileReleased) {
          _closing = null;
        }
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _close({required bool wasRunning}) async {
    try {
      await _drained;
    } on FileSelectionCleanupFailure {
      // Report this drain's original failure before a later close retries it.
      if (wasRunning) rethrow;
      final failure = _fileFailure!;
      if (!_fileReleased) {
        try {
          await failure.selection.dispose();
          _fileReleased = true;
        } catch (error, stack) {
          throw FileSelectionCleanupFailure(
            selection: failure.selection,
            cleanupError: error,
            cleanupStack: stack,
            operationError: failure.operationError,
            operationStack: failure.operationStack,
          );
        }
      }
      if (failure.operationError is DioCleanupFailure) {
        Error.throwWithStackTrace(
          failure.operationError!,
          failure.operationStack ?? failure.cleanupStack,
        );
      }
      _detach();
    }
  }
}

/// Keeps an idle preview's file on its original window until release or transfer.
class SourceSelectionOwner {
  SourceSelectionOwner(BuildContext context, this.selection)
    : _context = context,
      _window = context.getInheritedWidgetOfExactType<WindowFrameController>(),
      _registry = context
          .getInheritedWidgetOfExactType<SelectionTasksScope>()
          ?.registry {
    // Reject before adopting: the inspection still owns this late selection.
    if (_registry?.isClosing == true || _window?.isClosing == true) {
      throw StateError('Source selection host is closing');
    }
    _releaseHost = _registry?.retain(cancel: _cancel, close: closeAndWait);
    _window?.addExitTask(closeAndWait);
  }

  final FileSelection selection;
  final BuildContext _context;
  final WindowFrameController? _window;
  final SelectionTaskRegistry? _registry;
  void Function()? _releaseHost;
  bool _detached = false;
  bool _closingRequested = false;
  bool _transferring = false;
  Future<void>? _closing;
  Object? _operationError;
  StackTrace? _operationStack;

  void _cancel() => _closingRequested = true;

  void _detach() {
    _detached = true;
    _window?.removeExitTask(closeAndWait);
    _releaseHost?.call();
    _releaseHost = null;
  }

  void transfer(bool Function(FileSelection) accept) {
    if (_closingRequested ||
        _detached ||
        _transferring ||
        !_context.mounted ||
        _context
                .getInheritedWidgetOfExactType<SelectionTasksScope>()
                ?.registry !=
            _registry ||
        _context
                .getInheritedWidgetOfExactType<WindowFrameController>()
                ?.addExitTask !=
            _window?.addExitTask ||
        _registry?.isClosing == true ||
        _window?.isClosing == true) {
      throw StateError('Selected file cannot be transferred');
    }
    _transferring = true;
    try {
      if (accept(selection)) _detach();
    } catch (error, stack) {
      _operationError = error;
      _operationStack = stack;
      rethrow;
    } finally {
      _transferring = false;
    }
  }

  Future<void> closeAndWait() {
    final previous = _closing;
    if (previous != null) return previous;
    _cancel();
    final done = Completer<void>();
    _closing = done.future;
    // Synchronous acceptance may reenter host close. Keep registration until
    // acceptance returns, and only then decide which owner releases the file.
    Future<void>.microtask(_close).then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        _closing = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _close() async {
    if (_detached) return;
    try {
      await selection.dispose();
      _detach();
    } catch (error, stack) {
      throw FileSelectionCleanupFailure(
        selection: selection,
        cleanupError: error,
        cleanupStack: stack,
        operationError: _operationError,
        operationStack: _operationStack,
      );
    }
  }

  void release({Object? cause, StackTrace? stackTrace}) {
    if (cause != null) {
      _operationError = cause;
      _operationStack = stackTrace;
    }
    final pending = closeAndWait();
    _window?.trackExitTask(pending);
    unawaited(
      pending.catchError((Object error, StackTrace stack) {
        Log.error('Source selection cleanup', error, stack);
      }),
    );
  }
}
