import 'dart:async';
import 'dart:collection';

/// Coordinates live data access with exclusive archive/replacement operations.
/// Access must be acquired before joining a resource's own mutation queue.
class AppDataOperations {
  static final instance = AppDataOperations();

  final _scopeKey = Object();
  final _queue = Queue<_AppDataOperation>();
  int _accesses = 0;
  bool _exclusive = false;

  /// New accesses queue behind a waiting replacement; existing accesses can
  /// finish concurrently. The action owns all database/file work it starts.
  Future<T> access<T>(FutureOr<T> Function() action) =>
      _submit(action, exclusive: false);

  /// Synchronous bridges cannot wait behind a replacement. Reject before the
  /// action starts, preserving their return-value contract without bypassing
  /// queued exclusive work. Asynchronous callers should use [access] instead.
  /// The action must finish synchronously; register descendants with [access].
  T accessSync<T>(T Function() action) {
    final current = Zone.current[_scopeKey] as _AppDataScope?;
    if (current != null && current.active) return action();
    if (_exclusive || _queue.isNotEmpty) throw AppDataBusyException();
    final scope = _AppDataScope(false);
    _accesses++;
    try {
      return runZoned(action, zoneValues: {_scopeKey: scope});
    } finally {
      if (scope._pending.isEmpty) {
        scope.active = false;
        _accesses--;
        _admit();
      } else {
        // Explicitly registered descendants still own their real completion,
        // even when a synchronous callback has already returned or thrown.
        unawaited(
          scope.drain().then((_) {
            _accesses--;
            _admit();
          }),
        );
      }
    }
  }

  /// Freeze admission immediately, then wait for every earlier access. Nested
  /// calls made by this operation reuse its live, operation-scoped capability.
  Future<T> run<T>(FutureOr<T> Function() action) =>
      _submit(action, exclusive: true);

  /// Publish synchronous notifications without lending the operation's access
  /// to listeners or their asynchronous callbacks. Work started by a listener
  /// acquires its own place in the queue; the publisher must not await it.
  void publish(void Function() notify) =>
      runZoned(notify, zoneValues: {_scopeKey: null});

  Future<T> _submit<T>(
    FutureOr<T> Function() action, {
    required bool exclusive,
  }) {
    final scope = Zone.current[_scopeKey] as _AppDataScope?;
    if (scope != null && scope.active) {
      if (exclusive && !scope.exclusive) {
        return Future.error(
          StateError('Live data access cannot upgrade itself to replacement'),
        );
      }
      return scope.nest(action);
    }
    final result = Completer<T>();
    final caller = Zone.current;
    _queue.add(
      _AppDataOperation(exclusive, () {
        caller.run(() {
          _execute(
            action,
            exclusive: exclusive,
          ).then(result.complete, onError: result.completeError);
        });
      }),
    );
    _admit();
    return result.future;
  }

  void _admit() {
    while (!_exclusive && _queue.isNotEmpty) {
      final next = _queue.first;
      if (next.exclusive && _accesses != 0) return;
      _queue.removeFirst();
      if (next.exclusive) {
        _exclusive = true;
      } else {
        _accesses++;
      }
      next.start();
    }
  }

  Future<T> _execute<T>(
    FutureOr<T> Function() action, {
    required bool exclusive,
  }) async {
    final scope = _AppDataScope(exclusive);
    try {
      return await runZoned(
        () => Future<T>.sync(action),
        zoneValues: {_scopeKey: scope},
      );
    } finally {
      // A nested accepted write can outlive the immediate action. Keep its
      // capability valid until all descendants finish, including failed work.
      await scope.drain();
      if (exclusive) {
        _exclusive = false;
      } else {
        _accesses--;
      }
      _admit();
    }
  }
}

class AppDataBusyException implements Exception {
  @override
  String toString() =>
      'Application data is busy; retry after the current data operation completes';
}

class _AppDataOperation {
  const _AppDataOperation(this.exclusive, this.start);
  final bool exclusive;
  final void Function() start;
}

class _AppDataScope {
  _AppDataScope(this.exclusive);
  final bool exclusive;
  bool active = true;
  final _pending = <Future<void>>{};

  Future<T> nest<T>(FutureOr<T> Function() action) {
    final result = Completer<T>();
    late final Future<void> settled;
    settled = Future<T>.sync(action)
        .then<void>(result.complete, onError: result.completeError)
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    return result.future;
  }

  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    // Seal before yielding back to the owner. A late microtask must not add
    // descendants after an empty drain has already decided to release access.
    active = false;
  }
}
