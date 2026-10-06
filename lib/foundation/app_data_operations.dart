import 'dart:async';
import 'dart:collection';

/// Coordinates live data access with exclusive archive/replacement operations.
/// Access must be acquired before joining a resource's own mutation queue.
class AppDataOperations {
  static final instance = AppDataOperations();

  final _scopeKey = Object();
  final _preparationKey = Object();
  final _queue = Queue<_AppDataOperation>();
  int _accesses = 0;
  bool _exclusive = false;
  bool _preparing = false;
  bool _closing = false;
  Future<void>? _closeAttempt;
  FutureOr<void> Function()? _finalize;

  bool get isClosing => _closing;

  /// Irreversibly stop new owners, drain admitted work, then persist the final
  /// state with exclusive access. The finalizer may be retried after failure;
  /// ordinary admission never reopens. Stop native producers before calling.
  Future<void> closeAndWait({FutureOr<void> Function()? finalize}) {
    if (sharingScope != null) {
      return Future.error(
        StateError('Close data admission outside an operation'),
      );
    }
    final pending = _closeAttempt;
    if (pending != null) return pending;
    if (!_closing) _finalize = finalize;
    _closing = true;
    final completion = Completer<void>();
    _closeAttempt = completion.future;
    _enqueue<void>(
      () => _finalize?.call(),
      kind: _AppDataOperationKind.exclusive,
    ).then(
      completion.complete,
      onError: (Object error, StackTrace stack) {
        _closeAttempt = null;
        completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  /// Identity for sharing a Future only within the same live admission. A
  /// queued request outside an operation must not be reused by its owner.
  Object? get sharingScope {
    final data = Zone.current[_scopeKey] as _AppDataScope?;
    if (data != null && data.active) return data;
    final preparation = Zone.current[_preparationKey] as _AppDataScope?;
    return preparation != null && preparation.active ? preparation : null;
  }

  /// New accesses queue behind a waiting replacement unless a preparation is
  /// still active. The action owns all database/file work it starts.
  Future<T> access<T>(FutureOr<T> Function() action) =>
      _submit(action, kind: _AppDataOperationKind.access);

  /// Reserve a place before entering a resource's mutation queue. Preparations
  /// serialize with each other and replacement, without owning ordinary data
  /// access across network/init waits. While one is active, ordinary accesses
  /// may pass queued replacements so native callbacks can finish preparation.
  Future<T> prepare<T>(FutureOr<T> Function() action) =>
      _submit(action, kind: _AppDataOperationKind.preparation);

  /// Synchronous bridges cannot wait behind a replacement. Reject before the
  /// action starts, preserving their return-value contract without bypassing
  /// active exclusive work. During preparation, queued replacement waits while
  /// ordinary accesses remain allowed. Async callers should use [access].
  /// The action must finish synchronously; register descendants with [access].
  T accessSync<T>(T Function() action) {
    final current = Zone.current[_scopeKey] as _AppDataScope?;
    if (current != null && current.active) return action();
    if (_closing && !_preparing) throw AppDataClosedException();
    if (_exclusive || (!_preparing && _queue.isNotEmpty)) {
      throw AppDataBusyException();
    }
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

  /// Wait for earlier preparation, then freeze ordinary admission and drain
  /// accepted accesses. Nested calls reuse the live exclusive capability.
  Future<T> run<T>(FutureOr<T> Function() action) =>
      _submit(action, kind: _AppDataOperationKind.exclusive);

  /// Publish synchronous notifications without lending the operation's access
  /// to listeners or their asynchronous callbacks. Work started by a listener
  /// acquires its own place in the queue; the publisher must not await it.
  void publish(void Function() notify) =>
      runZoned(notify, zoneValues: {_scopeKey: null, _preparationKey: null});

  Future<T> _submit<T>(
    FutureOr<T> Function() action, {
    required _AppDataOperationKind kind,
  }) {
    final scope = Zone.current[_scopeKey] as _AppDataScope?;
    if (scope != null && scope.active) {
      if (kind != _AppDataOperationKind.access && !scope.exclusive) {
        return Future.error(
          StateError(
            'Live data access cannot upgrade to preparation/replacement',
          ),
        );
      }
      return scope.nest(action);
    }
    final preparation = Zone.current[_preparationKey] as _AppDataScope?;
    if (preparation != null && preparation.active) {
      if (kind == _AppDataOperationKind.exclusive) {
        return Future.error(
          StateError('Preparation cannot upgrade itself to replacement'),
        );
      }
      if (kind == _AppDataOperationKind.preparation) {
        return preparation.nest(action);
      }
    }
    // A native callback from an already admitted preparation can lose its
    // Dart zone. Let ordinary accesses finish that preparation, but admit no
    // new preparation/replacement. Once it settles, all new owners are sealed.
    if (_closing && !(kind == _AppDataOperationKind.access && _preparing)) {
      return Future.error(AppDataClosedException());
    }
    return _enqueue(action, kind: kind);
  }

  Future<T> _enqueue<T>(
    FutureOr<T> Function() action, {
    required _AppDataOperationKind kind,
  }) {
    final result = Completer<T>();
    final caller = Zone.current;
    _queue.add(
      _AppDataOperation(kind, () {
        caller.run(() {
          _execute(
            action,
            kind: kind,
          ).then(result.complete, onError: result.completeError);
        });
      }),
    );
    _admit();
    return result.future;
  }

  void _admit() {
    while (!_exclusive && _queue.isNotEmpty) {
      _AppDataOperation? next;
      if (_preparing) {
        // Native JS callbacks may arrive without the initiating Dart Zone.
        // All ordinary accesses remain admissible until preparation settles.
        for (final queued in _queue) {
          if (queued.kind == _AppDataOperationKind.access) {
            next = queued;
            break;
          }
        }
        if (next == null) return;
      } else {
        next = _queue.first;
      }
      if (next.kind == _AppDataOperationKind.exclusive && _accesses != 0) {
        return;
      }
      _queue.remove(next);
      switch (next.kind) {
        case _AppDataOperationKind.exclusive:
          _exclusive = true;
        case _AppDataOperationKind.preparation:
          _preparing = true;
        case _AppDataOperationKind.access:
          _accesses++;
      }
      next.start();
    }
  }

  Future<T> _execute<T>(
    FutureOr<T> Function() action, {
    required _AppDataOperationKind kind,
  }) async {
    final scope = _AppDataScope(kind == _AppDataOperationKind.exclusive);
    try {
      return await runZoned(
        () => Future<T>.sync(action),
        zoneValues: {
          if (kind == _AppDataOperationKind.preparation)
            _preparationKey: scope
          else
            _scopeKey: scope,
        },
      );
    } finally {
      // A nested accepted write can outlive the immediate action. Keep its
      // capability valid until all descendants finish, including failed work.
      await scope.drain();
      switch (kind) {
        case _AppDataOperationKind.exclusive:
          _exclusive = false;
        case _AppDataOperationKind.preparation:
          _preparing = false;
        case _AppDataOperationKind.access:
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

class AppDataClosedException implements Exception {
  @override
  String toString() => 'Application data is closing';
}

enum _AppDataOperationKind { access, preparation, exclusive }

class _AppDataOperation {
  const _AppDataOperation(this.kind, this.start);
  final _AppDataOperationKind kind;
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
