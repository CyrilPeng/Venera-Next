import 'dart:async';

import 'operation_failure.dart';
import 'window_placement.dart';

class WindowPlacementFailure implements FailureDetails {
  WindowPlacementFailure(
    Iterable<({String operation, Object error, StackTrace stackTrace})>
    failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String operation, Object error, StackTrace stackTrace})>
  failures;

  @override
  FailureKind get kind => FailureKind.failed;

  @override
  String get message =>
      'Window placement failed: ${failures.map((failure) => failure.operation).join(', ')}';

  @override
  Object? get cause => failures.firstOrNull?.error;

  @override
  StackTrace? get stackTrace => failures.firstOrNull?.stackTrace;

  @override
  String toString() => message;
}

/// Owns one mount's periodic window queries and complete placement writes.
/// The host supplies readiness and serializes transfer to replacement mounts.
class WindowPlacementTracker {
  WindowPlacementTracker({
    required Future<WindowPlacement?> Function() read,
    required Future<void> Function(WindowPlacement placement) save,
    required Future<void> ready,
    void Function(Object error, StackTrace stackTrace)? onError,
    Duration interval = const Duration(milliseconds: 100),
  }) : _read = read,
       _save = save,
       _onError = onError,
       _interval = interval {
    unawaited(_observeReady(ready));
  }

  final Future<WindowPlacement?> Function() _read;
  final Future<void> Function(WindowPlacement placement) _save;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  final Duration _interval;
  final _readySignal = Completer<void>();
  final _disposeSignal = Completer<void>();
  final _holds = <Object>{};
  // Bound persistent failure diagnostics while still reporting every attempt.
  final _failures =
      <String, ({String operation, Object error, StackTrace stackTrace})>{};
  final _reportingFailures =
      <String, ({String operation, Object error, StackTrace stackTrace})>{};
  bool _ready = false;
  bool _startRequested = false;
  bool _disposed = false;
  Timer? _timer;
  Object? _timerOwner;
  WindowPlacement? _savedPlacement;
  Future<void>? _active;
  Future<void>? _preparing;
  Future<void>? _closing;

  Future<void> _observeReady(Future<void> ready) async {
    try {
      await ready;
      _ready = true;
      _ensureTimer();
    } catch (error, stackTrace) {
      // The shared host may outlive this mount. Observe its eventual failure,
      // but a disposed mount no longer owns that readiness result.
      if (!_disposed) _recordFailure('ready', error, stackTrace);
    } finally {
      _readySignal.complete();
    }
  }

  /// Requests polling after the window is ready, retaining the original delay
  /// before the first query so native show/maximize calls can finish settling.
  void start() {
    if (_disposed) throw StateError('Window placement tracker is disposed');
    _startRequested = true;
    _ensureTimer();
  }

  void _ensureTimer() {
    if (_disposed ||
        !_startRequested ||
        !_ready ||
        _holds.isNotEmpty ||
        _timer != null) {
      return;
    }
    final owner = _timerOwner = Object();
    _timer = Timer.periodic(_interval, (_) {
      if (_disposed ||
          !identical(_timerOwner, owner) ||
          _holds.isNotEmpty ||
          _active != null) {
        return;
      }
      // A busy tick is skipped. There is no backlog of native queries/writes.
      _beginSample();
    });
  }

  void _stopTimer() {
    _timerOwner = null;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _beginSample() {
    final completed = Completer<void>();
    // Register before invoking adapters; synchronous read callbacks may close
    // their owner, and that close must include this accepted operation.
    _active = completed.future;
    unawaited(_sample(completed));
    return completed.future;
  }

  Future<void> _sample(Completer<void> completed) async {
    var operation = 'read';
    try {
      final current = await _read();
      // Minimized/transient windows have no stable snapshot. Skipping one
      // cannot acknowledge or repair an earlier unsuccessful write.
      if (current == null) return;
      if (current != _savedPlacement) {
        operation = 'save';
        await _save(current);
        _savedPlacement = current;
      }
      // The latest complete snapshot now matches persisted state. Earlier
      // read/write failures are repaired, but reporting failures remain visible.
      _failures
        ..remove('read')
        ..remove('save');
    } catch (error, stackTrace) {
      // An unsuccessful write may already have truncated or partly replaced
      // the file. Even a return to the previous bounds then requires a write.
      if (operation == 'save') _savedPlacement = null;
      _recordFailure(operation, error, stackTrace);
    } finally {
      if (identical(_active, completed.future)) _active = null;
      completed.complete();
    }
  }

  void _recordFailure(String operation, Object error, StackTrace stackTrace) {
    _failures[operation] = (
      operation: operation,
      error: error,
      stackTrace: stackTrace,
    );
    try {
      _onError?.call(error, stackTrace);
    } catch (reportingError, reportingStackTrace) {
      _reportingFailures[operation] = (
        operation: 'report',
        error: reportingError,
        stackTrace: reportingStackTrace,
      );
    }
  }

  void _checkFailures() {
    final failures = [..._failures.values, ..._reportingFailures.values];
    if (failures.isNotEmpty) throw WindowPlacementFailure(failures);
  }

  /// Freeze immediately, join accepted work and sample one final placement.
  /// Concurrent callers share that drain, but each receives its own hold.
  /// A failed preparation releases only its own hold and can be retried later.
  Future<void Function()> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('Window placement tracker is disposed'));
    }
    final hold = Object();
    _holds.add(hold);
    _stopTimer();
    void release() {
      if (!_holds.remove(hold) || _disposed) return;
      _ensureTimer();
    }

    final preparing = _preparing ?? _beginPreparation();
    return preparing.then(
      (_) => release,
      onError: (Object error, StackTrace stackTrace) {
        release();
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  Future<void> _beginPreparation() {
    final completed = Completer<void>();
    _preparing = completed.future;
    unawaited(_prepare(completed));
    return completed.future;
  }

  Future<void> _prepare(Completer<void> completed) async {
    try {
      if (_startRequested) {
        await Future.any([_readySignal.future, _disposeSignal.future]);
        if (_disposed) throw StateError('Window placement tracker is disposed');
        if (!_ready) _checkFailures();
      }
      final active = _active;
      if (active != null) await active;
      if (_disposed) throw StateError('Window placement tracker is disposed');
      if (_startRequested && _ready) await _beginSample();
      if (_disposed) throw StateError('Window placement tracker is disposed');
      _checkFailures();
      completed.complete();
    } catch (error, stackTrace) {
      completed.completeError(error, stackTrace);
    } finally {
      if (identical(_preparing, completed.future)) _preparing = null;
    }
  }

  /// Stop permanently and join real work already admitted by this owner.
  /// Unresolved shared readiness is cancelled locally, without delaying close.
  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    _stopTimer();
    _holds.clear();
    _disposeSignal.complete();
    final completed = Completer<void>();
    _closing = completed.future;
    unawaited(_dispose(completed));
    return completed.future;
  }

  Future<void> _dispose(Completer<void> completed) async {
    try {
      final active = _active;
      if (active != null) await active;
      final preparing = _preparing;
      if (preparing != null) {
        // Preparation cancellation is expected. Accepted adapter failures are
        // retained independently and still form the final disposal result.
        await preparing.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
      }
      _checkFailures();
      completed.complete();
    } catch (error, stackTrace) {
      completed.completeError(error, stackTrace);
    }
  }
}
