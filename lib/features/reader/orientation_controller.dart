import 'dart:async';

enum ReaderOrientation { system, portrait, landscape }

/// One coordinator per application orientation scope; owners are plain handles,
/// never Widget States. Platform requests retain their immediate issue order.
class ReaderOrientationCoordinator {
  ReaderOrientationCoordinator({required this.apply, required this.onError});
  final Future<void> Function(ReaderOrientation) apply;
  final void Function(Object, StackTrace) onError;
  final _owners = <ReaderOrientationHandle>[];
  bool _disposed = false;

  ReaderOrientationHandle acquire() {
    if (_disposed) throw StateError('Orientation scope is disposed');
    final owner = ReaderOrientationHandle._(this);
    _owners.add(owner);
    _publish(owner.orientation);
    return owner;
  }

  void _publish(ReaderOrientation orientation) {
    unawaited(Future<void>.sync(() => apply(orientation)).catchError(onError));
  }

  void _release(ReaderOrientationHandle owner) {
    if (_disposed) return;
    final wasActive = identical(_owners.lastOrNull, owner);
    _owners.remove(owner);
    if (wasActive) {
      _publish(_owners.lastOrNull?.orientation ?? ReaderOrientation.system);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final hadOwners = _owners.isNotEmpty;
    _owners.clear();
    if (hadOwners) _publish(ReaderOrientation.system);
  }
}

class ReaderOrientationHandle {
  ReaderOrientationHandle._(this._coordinator);
  final ReaderOrientationCoordinator _coordinator;
  ReaderOrientation _orientation = ReaderOrientation.system;
  bool _disposed = false;
  ReaderOrientation get orientation => _orientation;

  bool cycle() {
    if (_disposed ||
        _coordinator._disposed ||
        !identical(_coordinator._owners.lastOrNull, this)) {
      return false;
    }
    _orientation = switch (_orientation) {
      ReaderOrientation.system => ReaderOrientation.portrait,
      ReaderOrientation.portrait => ReaderOrientation.landscape,
      ReaderOrientation.landscape => ReaderOrientation.system,
    };
    _coordinator._publish(_orientation);
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _coordinator._release(this);
  }
}
