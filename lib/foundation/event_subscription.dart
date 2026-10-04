import 'dart:async';
import 'dart:collection';

/// Serial event handling with an explicit lifetime, including awaited handlers.
class EventSubscription<T> {
  EventSubscription({
    required this.events,
    required this.handle,
    required this.onError,
  });
  final Stream<T> events;
  final Future<void> Function(T event, bool Function() isActive) handle;
  final void Function(Object error, StackTrace stack) onError;
  StreamSubscription<T>? _subscription;
  final _pending = Queue<T>();
  Future<void>? _handling;
  Future<void Function()>? _preparation;
  Object? _exitHold;
  Future<void>? _disposal;
  bool _disposed = false;
  int _generation = 0;

  bool get _accepting => !_disposed && _exitHold == null;

  void start() {
    if (_disposed) throw StateError('Event subscription is disposed');
    if (_subscription != null) return;
    // Keep listening during a hold so rejected platform events cannot be
    // buffered by a paused subscription and replayed after recovery.
    _subscription = events.listen(_enqueue, onError: _reportError);
  }

  void _enqueue(T event) {
    if (!_accepting) return;
    _pending.add(event);
    if (_handling != null) return;
    final done = Completer<void>();
    _handling = done.future;
    unawaited(_drain(done));
  }

  Future<void> _drain(Completer<void> done) async {
    try {
      while (_accepting && _pending.isNotEmpty) {
        final event = _pending.removeFirst();
        final generation = _generation;
        try {
          await handle(event, () => _accepting && generation == _generation);
        } catch (error, stack) {
          // Cancellation of the stream must not hide a late handler failure.
          _reportError(error, stack);
        }
      }
    } finally {
      _handling = null;
      done.complete();
    }
  }

  void _reportError(Object error, StackTrace stack) {
    try {
      onError(error, stack);
    } catch (reportError, reportStack) {
      Zone.current.handleUncaughtError(reportError, reportStack);
    }
  }

  /// Invalidate active handlers, discard queued events and await real work.
  /// The subscription stays attached and drops incoming events until release.
  Future<void Function()> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('Event subscription is disposed'));
    }
    final preparation = _preparation;
    if (preparation != null) return preparation;
    final hold = Object();
    _exitHold = hold;
    _generation++;
    _pending.clear();
    return _preparation = _prepare(hold);
  }

  Future<void Function()> _prepare(Object hold) async {
    await _handling;
    return () {
      if (_disposed || !identical(_exitHold, hold)) return;
      _exitHold = null;
      _preparation = null;
    };
  }

  Future<void> dispose() {
    final disposal = _disposal;
    if (disposal != null) return disposal;
    _disposed = true;
    _generation++;
    _pending.clear();
    // cancel() only detaches the stream; it does not join an async handler.
    final done = Completer<void>();
    _disposal = done.future;
    done.complete(
      Future.wait<void>([
        Future<void>.sync(() => _subscription?.cancel()),
        ?_handling,
      ]).then((_) {}),
    );
    return done.future;
  }
}
