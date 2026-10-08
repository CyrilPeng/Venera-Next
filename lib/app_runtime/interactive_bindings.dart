import 'dart:async';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';

/// Platform listeners and heartbeat belong to the mounted interactive app.
class InteractiveBindings {
  InteractiveBindings({
    required this.android,
    required this.windows,
    required this.links,
    required this.shares,
    required this.heartbeat,
    this.closeHeartbeat,
    this.placement,
    this.onError = _logError,
  });

  final bool android;
  final bool windows;
  final EventSubscription<Uri> Function() links;
  final EventSubscription<Object?> Function() shares;
  final Future<void> Function() heartbeat;
  final Future<void> Function()? closeHeartbeat;
  final WindowPlacementTracker? placement;
  final void Function(Object error, StackTrace stack) onError;
  EventSubscription<Uri>? _links;
  EventSubscription<Object?>? _shares;
  Timer? _heartbeat;
  final _pendingHeartbeats = <Future<void>>{};
  bool _started = false;
  bool _startAfterPreparation = false;
  bool _disposed = false;
  Future<void>? _disposal;
  Future<void Function()>? _preparation;
  Object? _exitHold;

  static void _logError(Object error, StackTrace stack) =>
      Log.error('Interactive bindings', error, stack);

  void _reportError(Object error, StackTrace stack) {
    try {
      onError(error, stack);
    } catch (reportError, reportStack) {
      Zone.current.handleUncaughtError(reportError, reportStack);
    }
  }

  void start() {
    if (_disposed) throw StateError('Interactive bindings are disposed');
    if (_started) return;
    if (_exitHold != null) {
      _startAfterPreparation = true;
      return;
    }
    _started = true;
    try {
      placement?.start();
      if (android) {
        _links = links();
        _links!.start();
        _shares = shares();
        _shares!.start();
      }
      if (windows) {
        _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_disposed) return;
          final done = Completer<void>();
          _pendingHeartbeats.add(done.future);
          unawaited(_sendHeartbeat(done));
        });
      }
    } catch (_) {
      unawaited(dispose().catchError(_reportError));
      rethrow;
    }
  }

  Future<void> _sendHeartbeat(Completer<void> done) async {
    try {
      await heartbeat();
    } catch (error, stack) {
      _reportError(error, stack);
    } finally {
      _pendingHeartbeats.remove(done.future);
      done.complete();
    }
  }

  /// Freeze platform actions while keeping the Windows watchdog alive during
  /// potentially slow, recoverable shutdown preparation.
  Future<void Function()> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('Interactive bindings are disposed'));
    }
    final preparation = _preparation;
    if (preparation != null) return preparation;
    final hold = Object();
    _exitHold = hold;
    return _preparation = _prepare(hold);
  }

  Future<void Function()> _prepare(Object hold) async {
    final releases = <({String binding, void Function() resume})>[];
    final failures = <({String binding, Object error, StackTrace stack})>[];
    Future<void> prepare(
      String binding,
      Future<void Function()> Function() action,
    ) async {
      try {
        releases.add((binding: binding, resume: await action()));
      } catch (error, stack) {
        failures.add((binding: binding, error: error, stack: stack));
      }
    }

    var released = false;
    void release() {
      if (released) return;
      released = true;
      final failures = <({String binding, Object error, StackTrace stack})>[];
      for (final binding in releases.reversed) {
        try {
          binding.resume();
        } catch (error, stack) {
          failures.add((
            binding: '${binding.binding} resume',
            error: error,
            stack: stack,
          ));
        }
      }
      if (!_disposed && identical(_exitHold, hold)) {
        _exitHold = null;
        _preparation = null;
        if (_startAfterPreparation) {
          _startAfterPreparation = false;
          try {
            start();
          } catch (error, stack) {
            failures.add((binding: 'start', error: error, stack: stack));
          }
        }
      }
      if (failures.isNotEmpty) {
        throw InteractiveBindingsPreparationFailure(failures);
      }
    }

    await Future.wait<void>([
      if (_links != null) prepare('links', _links!.prepareForExit),
      if (_shares != null) prepare('shares', _shares!.prepareForExit),
      if (placement != null)
        prepare('window placement', placement!.prepareForExit),
    ]);
    if (failures.isNotEmpty) {
      try {
        release();
      } on InteractiveBindingsPreparationFailure catch (error) {
        failures.addAll(error.failures);
      }
      throw InteractiveBindingsPreparationFailure(failures);
    }
    return release;
  }

  Future<void> dispose() {
    final disposal = _disposal;
    if (disposal != null) return disposal;
    _disposed = true;
    _heartbeat?.cancel();
    final done = Completer<void>();
    _disposal = done.future;
    done.complete(_dispose());
    return done.future;
  }

  Future<void> _dispose() async {
    final failures = <({String binding, Object error, StackTrace stack})>[];
    Future<void> close(String name, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        failures.add((binding: name, error: error, stack: stack));
      }
    }

    Future<void> closeWatchdog() async {
      await Future.wait<void>(_pendingHeartbeats);
      final stopHeartbeat = closeHeartbeat;
      if (stopHeartbeat != null) await close('heartbeat', stopHeartbeat);
    }

    await Future.wait<void>([
      if (_links != null) close('links', _links!.dispose),
      if (_shares != null) close('shares', _shares!.dispose),
      if (placement != null) close('window placement', placement!.dispose),
      // Its timer has stopped. Release the native watchdog after its own calls
      // drain, so a slow file write cannot leave an un-fed watchdog timing out.
      closeWatchdog(),
    ]);
    if (failures.isNotEmpty) throw InteractiveBindingsCloseFailure(failures);
  }
}

class InteractiveBindingsPreparationFailure implements Exception {
  InteractiveBindingsPreparationFailure(
    Iterable<({String binding, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String binding, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Interactive bindings preparation failed: '
      '${failures.map((failure) => '${failure.binding}: ${failure.error}').join('; ')}';
}

class InteractiveBindingsCloseFailure implements Exception {
  InteractiveBindingsCloseFailure(
    Iterable<({String binding, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String binding, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Interactive bindings close failed: '
      '${failures.map((failure) => '${failure.binding}: ${failure.error}').join('; ')}';
}
