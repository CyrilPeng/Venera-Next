import 'dart:async';

class ReaderWindowFailure implements Exception {
  ReaderWindowFailure(
    Iterable<({String operation, Object error, StackTrace stackTrace})>
    failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String operation, Object error, StackTrace stackTrace})>
  failures;

  @override
  String toString() => failures
      .map((failure) => '${failure.operation}: ${failure.error}')
      .join('; ');
}

typedef _WindowFailure = ({
  String operation,
  Object error,
  StackTrace stackTrace,
});

void _throwFailures(List<_WindowFailure> failures) {
  if (failures.length == 1) {
    Error.throwWithStackTrace(
      failures.single.error,
      failures.single.stackTrace,
    );
  }
  if (failures.isNotEmpty) throw ReaderWindowFailure(failures);
}

/// One coordinator per native window, surviving reader/widget replacement.
/// The latest live owner supplies policy; every transition shares this queue.
class ReaderWindowCoordinator {
  ReaderWindowCoordinator({
    required this.hide,
    required this.show,
    required this.setFullscreen,
  });

  final Future<void> Function() hide, show;
  final Future<void> Function(bool) setFullscreen;
  final _owners = <ReaderWindowController>[];
  final _frames = <Object, _WindowFrameEffect>{};
  Future<void>? _tail;
  bool _fullscreen = false;
  bool _fullscreenKnown = true;
  bool _showNeeded = false;
  bool? _pendingTarget;

  bool _isCurrent(ReaderWindowController owner) =>
      identical(_owners.lastOrNull, owner);

  void _attach(ReaderWindowController owner) {
    owner._requestedFullscreen =
        _owners.lastOrNull?._requestedFullscreen ?? false;
    _owners.add(owner);
    _frames.putIfAbsent(
      owner.frameIdentity,
      () =>
          _WindowFrameEffect(owner.setFrameVisible, owner.initialFrameVisible),
    );
  }

  Future<void> _schedule() {
    final operation = (_tail ?? Future<void>.value()).then((_) => _reconcile());
    late final Future<void> tail;
    void settled() {
      // An idle coordinator must not retain a completed Future's old Zone.
      if (identical(_tail, tail)) _tail = null;
    }

    tail = operation.then<void>(
      (_) => settled(),
      onError: (Object _, StackTrace _) => settled(),
    );
    _tail = tail;
    return operation;
  }

  Future<void> _reconcile() async {
    final owner = _owners.lastOrNull;
    final target = owner != null && !owner._held && owner._requestedFullscreen;
    final failures = <_WindowFailure>[];
    Future<void> attempt(String name, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        failures.add((operation: name, error: error, stackTrace: stackTrace));
      }
    }

    if (!_fullscreenKnown || _fullscreen != target) {
      // A retry of the same unknown fullscreen request does not need another
      // hide. Its previous show may already have recovered window visibility.
      if (_pendingTarget != target) {
        _pendingTarget = target;
        _showNeeded = true;
        await attempt('hide', hide);
      }
      _fullscreenKnown = false;
      // Fullscreen itself can change native visibility on some platforms.
      _showNeeded = true;
      await attempt('fullscreen', () async {
        await setFullscreen(target);
        _fullscreen = target;
        _fullscreenKnown = true;
        _pendingTarget = null;
      });
    }
    if (_showNeeded) {
      await attempt('show', () async {
        await show();
        _showNeeded = false;
      });
    }
    for (final entry in _frames.entries.toList()) {
      final active = _owners.lastOrNull;
      final visible =
          active?.frameIdentity != entry.key ||
          !_fullscreenKnown ||
          !_fullscreen;
      final frame = entry.value;
      if (frame.visible != visible) {
        frame.visible = null;
        await attempt('frame', () {
          frame.setVisible(visible);
          frame.visible = visible;
        });
      }
      if (frame.visible == true &&
          !_owners.any((owner) => owner.frameIdentity == entry.key)) {
        _frames.remove(entry.key);
      }
    }
    _throwFailures(failures);
  }
}

class _WindowFrameEffect {
  _WindowFrameEffect(this.setVisible, this.visible);
  final void Function(bool) setVisible;
  bool? visible;
}

/// One reader's window policy, close listener and retryable release obligation.
class ReaderWindowController {
  ReaderWindowController({
    required this.coordinator,
    required this.frameIdentity,
    required this.initialFrameVisible,
    required this.setFrameVisible,
    required this.addCloseListener,
    required this.removeCloseListener,
    required this.canPop,
    required this.pop,
    required this.onError,
  });

  final ReaderWindowCoordinator coordinator;
  final Object frameIdentity;
  final bool initialFrameVisible;
  final void Function(bool) setFrameVisible;
  final void Function(bool Function()) addCloseListener, removeCloseListener;
  final bool Function() canPop;
  final void Function() pop;
  final void Function(Object, StackTrace) onError;
  bool _attached = false;
  bool _attaching = false;
  bool _listenerOwned = false;
  bool _disposed = false;
  bool _held = false;
  bool _requestedFullscreen = false;
  Future<void>? _attachingResult;
  Future<void>? _closing;

  Future<void> _report(Future<void> operation) async {
    try {
      await operation;
    } catch (error, stackTrace) {
      try {
        onError(error, stackTrace);
      } catch (reportError, reportStack) {
        throw ReaderWindowFailure([
          (operation: 'transition', error: error, stackTrace: stackTrace),
          (operation: 'report', error: reportError, stackTrace: reportStack),
        ]);
      }
      rethrow;
    }
  }

  Future<void> attach() {
    if (_disposed) return _closing ?? Future.value();
    if (_attachingResult case final result?) return result;
    final done = Completer<void>();
    _attachingResult = done.future;
    _attached = true;
    coordinator._attach(this);
    final failures = <_WindowFailure>[];
    _attaching = true;
    _listenerOwned = true; // A throwing registration may already have applied.
    try {
      addCloseListener(_onClose);
    } catch (error, stackTrace) {
      failures.add((
        operation: 'add listener',
        error: error,
        stackTrace: stackTrace,
      ));
    } finally {
      _attaching = false;
    }
    _report(_settle(failures)).then(done.complete, onError: done.completeError);
    return done.future;
  }

  bool _onClose() {
    if (_disposed || _held || !coordinator._isCurrent(this) || !canPop()) {
      return true;
    }
    pop();
    return false;
  }

  Future<void> toggle() {
    if (_disposed || _held || !coordinator._isCurrent(this)) {
      return Future.value();
    }
    _requestedFullscreen = !_requestedFullscreen;
    return _report(coordinator._schedule());
  }

  /// Reversible window preparation temporarily requests windowed mode. Resume
  /// restores the latest live owner's preference, not a stale native snapshot.
  Future<void> setHeld(bool held) {
    if (_disposed) return _closing ?? Future.value();
    _held = held;
    return _attached ? _report(coordinator._schedule()) : Future.value();
  }

  Future<void> _settle(List<_WindowFailure> failures) async {
    try {
      await coordinator._schedule();
    } catch (error, stackTrace) {
      if (error is ReaderWindowFailure) {
        failures.addAll(error.failures);
      } else {
        failures.add((
          operation: 'window',
          error: error,
          stackTrace: stackTrace,
        ));
      }
    }
    _throwFailures(failures);
  }

  Future<void> dispose() {
    if (_closing case final result?) return result;
    _disposed = true;
    coordinator._owners.remove(this);
    final done = Completer<void>();
    _closing = done.future;
    _report(_close()).then(
      done.complete,
      onError: (Object error, StackTrace stack) {
        _closing = null;
        done.completeError(error, stack);
      },
    );
    return done.future;
  }

  Future<void> _close() async {
    // Registration can reenter close before it actually installs the callback.
    if (_attaching) await Future<void>.value();
    final failures = <_WindowFailure>[];
    if (_listenerOwned) {
      try {
        removeCloseListener(_onClose);
        _listenerOwned = false;
      } catch (error, stackTrace) {
        failures.add((
          operation: 'remove listener',
          error: error,
          stackTrace: stackTrace,
        ));
      }
    }
    await _settle(failures);
  }
}
