import 'dart:async';

enum ReaderOrientation { system, portrait, landscape }

typedef ReaderPlatformFailure = ({
  String effect,
  Object error,
  StackTrace stackTrace,
});

class ReaderPlatformEffectsFailure implements Exception {
  ReaderPlatformEffectsFailure(Iterable<ReaderPlatformFailure> failures)
    : failures = List.unmodifiable(failures);
  final List<ReaderPlatformFailure> failures;

  @override
  String toString() => failures
      .map((failure) => '${failure.effect}: ${failure.error}')
      .join('; ');
}

/// One coordinator per native engine. Owners are plain handles, not States.
/// Acknowledgements describe the platform channel, not physical display state.
class ReaderPlatformEffectsCoordinator {
  ReaderPlatformEffectsCoordinator({
    required this.applyOrientation,
    required this.applySystemBars,
    required this.onError,
  });

  final Future<void> Function(ReaderOrientation) applyOrientation;
  final Future<void> Function(bool visible) applySystemBars;
  final void Function(Object, StackTrace) onError;
  final _owners = <ReaderPlatformEffectsHandle>[];
  Future<void>? _tail;
  ReaderOrientation? _orientation;
  bool? _systemBars;
  bool _orientationOwned = false;

  ReaderPlatformEffectsHandle createOwner({
    required bool orientationEnabled,
    bool systemBarsVisible = true,
  }) => ReaderPlatformEffectsHandle._(
    this,
    orientationEnabled,
    systemBarsVisible,
  );

  void _attach(ReaderPlatformEffectsHandle owner) {
    if (_owners.isEmpty) _systemBars = null;
    if (owner.orientationEnabled && !_orientationOwned) {
      _orientation = null;
      _orientationOwned = true;
    }
    _owners.add(owner);
  }

  Future<void> _schedule() {
    final operation = (_tail ?? Future<void>.value()).then((_) => _reconcile());
    late final Future<void> tail;
    void settled() {
      if (identical(_tail, tail)) _tail = null;
    }

    tail = operation.then<void>(
      (_) => settled(),
      onError: (Object _, StackTrace _) => settled(),
    );
    _tail = tail;
    return _report(operation);
  }

  Future<void> _report(Future<void> operation) async {
    try {
      await operation;
    } catch (error, stackTrace) {
      try {
        onError(error, stackTrace);
      } catch (reportError, reportStack) {
        throw ReaderPlatformEffectsFailure([
          (effect: 'platform', error: error, stackTrace: stackTrace),
          (effect: 'report', error: reportError, stackTrace: reportStack),
        ]);
      }
      rethrow;
    }
  }

  Future<void> _reconcile() async {
    final owner = _owners.lastOrNull;
    final orientation = owner?.orientationEnabled == true && !owner!.held
        ? owner.orientation
        : ReaderOrientation.system;
    final bars = owner == null || owner.held || owner._systemBarsVisible;
    Future<ReaderPlatformFailure?> attempt(
      String effect,
      Future<void> Function() apply,
    ) async {
      try {
        await apply();
        return null;
      } catch (error, stackTrace) {
        return (effect: effect, error: error, stackTrace: stackTrace);
      }
    }

    // Neither effect prevents the other from attempting restoration. A later
    // policy waits for both actual requests before it can reach the platform.
    final results = await Future.wait([
      if (_orientationOwned && _orientation != orientation)
        attempt('orientation', () async {
          _orientation = null;
          await applyOrientation(orientation);
          _orientation = orientation;
        }),
      if (_systemBars != bars)
        attempt('system bars', () async {
          _systemBars = null;
          await applySystemBars(bars);
          _systemBars = bars;
        }),
    ]);
    if (_orientation == ReaderOrientation.system &&
        !_owners.any((owner) => owner.orientationEnabled)) {
      _orientationOwned = false;
    }
    final failures = results.whereType<ReaderPlatformFailure>().toList();
    if (failures.length == 1) {
      Error.throwWithStackTrace(
        failures.single.error,
        failures.single.stackTrace,
      );
    }
    if (failures.isNotEmpty) throw ReaderPlatformEffectsFailure(failures);
  }
}

class ReaderPlatformEffectsHandle {
  ReaderPlatformEffectsHandle._(
    this._coordinator,
    this.orientationEnabled,
    this._systemBarsVisible,
  );

  final ReaderPlatformEffectsCoordinator _coordinator;
  final bool orientationEnabled;
  bool _systemBarsVisible;
  ReaderOrientation _orientation = ReaderOrientation.system;
  ReaderOrientation get orientation => _orientation;
  bool _attached = false;
  bool _disposed = false;
  final _holds = <Object>{};
  bool get held => _holds.isNotEmpty;
  bool get isClosed => _disposed;
  Future<void>? _attaching;
  Future<void>? _closing;

  Future<void> attach() {
    if (_disposed) return _closing ?? Future.value();
    if (_attaching case final attaching?) return attaching;
    _attached = true;
    _coordinator._attach(this);
    return _attaching = _coordinator._schedule();
  }

  Future<void>? cycleOrientation() {
    if (_disposed ||
        !_attached ||
        held ||
        !orientationEnabled ||
        !identical(_coordinator._owners.lastOrNull, this)) {
      return null;
    }
    _orientation = switch (_orientation) {
      ReaderOrientation.system => ReaderOrientation.portrait,
      ReaderOrientation.portrait => ReaderOrientation.landscape,
      ReaderOrientation.landscape => ReaderOrientation.system,
    };
    return refresh();
  }

  Future<void> setSystemBarsVisible(bool visible) {
    if (_disposed) return _closing ?? Future.value();
    _systemBarsVisible = visible;
    return refresh();
  }

  Future<void> hold(Object reason, bool held) {
    if (_disposed) return _closing ?? Future.value();
    if (held) {
      _holds.add(reason);
    } else {
      _holds.remove(reason);
    }
    return refresh();
  }

  Future<void> refresh() => _disposed
      ? _closing ?? Future.value()
      : _attached
      ? _coordinator._schedule()
      : Future.value();

  Future<void> closeAndWait() {
    if (_closing case final closing?) return closing;
    _disposed = true;
    _coordinator._owners.remove(this);
    final done = Completer<void>();
    _closing = done.future;
    final operation = _attached
        ? _coordinator._schedule()
        : Future<void>.value();
    operation.then(
      done.complete,
      onError: (Object error, StackTrace stackTrace) {
        _closing = null;
        done.completeError(error, stackTrace);
      },
    );
    return done.future;
  }
}
