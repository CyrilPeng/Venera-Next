import 'dart:async';

/// Owns image reads and platform deliveries, including work whose
/// originating widget has gone away. A cancellation stops the next stage;
/// completion is acknowledged only after the current stage actually returns.
class ImageWork {
  final _tasks = <ImageWorkTask>{};
  final _holds = <Object>{};
  final _resumeListeners = <({Object token, void Function() callback})>{};
  final _failures = <_ReportedWorkFailure>[];
  bool _disposed = false;
  bool _resuming = false;
  bool _resumePending = false;
  int _holdRevision = 0;
  Future<void>? _draining;
  Future<void>? _closing;

  /// Observe renewed admission after the last hold is released. Registration
  /// does not start work; callers should attempt [start] when first binding.
  /// Removing this subscription is safe during another listener's callback.
  void Function() addResumeListener(void Function() callback) {
    if (_disposed) return () {};
    final listener = (token: Object(), callback: callback);
    _resumeListeners.add(listener);
    return () => _resumeListeners.remove(listener);
  }

  ImageWorkTask? start({
    void Function()? cancelSelection,
    void Function()? onCancel,
  }) {
    if (_disposed || _holds.isNotEmpty) return null;
    final task = ImageWorkTask._(this, cancelSelection, onCancel);
    _tasks.add(task);
    return task;
  }

  void Function() holdForExit() {
    final hold = Object();
    if (_holds.isEmpty) _holdRevision++;
    _holds.add(hold);
    for (final task in _tasks.toList()) {
      task.cancel();
    }
    return () {
      if (!_holds.remove(hold) || _holds.isNotEmpty || _disposed) return;
      _notifyResume();
    };
  }

  void _notifyResume() {
    _resumePending = true;
    if (_resuming) return;
    _resuming = true;
    final failures = <({Object error, StackTrace stack})>[];
    try {
      while (_resumePending && !_disposed && _holds.isEmpty) {
        _resumePending = false;
        final revision = _holdRevision;
        for (final listener in _resumeListeners.toList()) {
          if (_disposed || _holds.isNotEmpty) break;
          // A callback may briefly hold and release admission again. Restart
          // the sweep so consumers it cancelled can bind, without recursion.
          if (revision != _holdRevision) break;
          if (!_resumeListeners.contains(listener)) continue;
          try {
            listener.callback();
          } catch (error, stack) {
            failures.add((error: error, stack: stack));
          }
        }
      }
    } finally {
      _resuming = false;
    }
    if (failures.isNotEmpty) throw ImageWorkFailure(failures);
  }

  Future<void Function()> prepareForExit() async {
    if (_disposed) throw StateError('Image work is closed');
    final release = holdForExit();
    try {
      await _drain();
      return release;
    } catch (error, stack) {
      try {
        release();
      } catch (resumeError, resumeStack) {
        Error.throwWithStackTrace(
          ImageWorkFailure([
            if (error is ImageWorkFailure)
              ...error.failures
            else
              (error: error, stack: stack),
            if (resumeError is ImageWorkFailure)
              ...resumeError.failures
            else
              (error: resumeError, stack: resumeStack),
          ]),
          stack,
        );
      }
      rethrow;
    }
  }

  Future<void> _drain() {
    if (_draining != null) return _draining!;
    final completion = Completer<void>();
    _draining = completion.future;
    unawaited(() async {
      while (_tasks.isNotEmpty) {
        await Future.wait(_tasks.map((task) => task.done).toList());
      }
      final failures = [
        for (final failure in _failures)
          (error: failure.error, stack: failure.stack),
      ];
      _failures.clear();
      _draining = null;
      if (failures.isEmpty) {
        completion.complete();
      } else {
        completion.completeError(ImageWorkFailure(failures));
      }
    }());
    return completion.future;
  }

  Future<void> dispose() {
    if (_closing != null) return _closing!;
    _disposed = true;
    _resumeListeners.clear();
    holdForExit();
    return _closing = _drain();
  }
}

class ImageWorkTask {
  ImageWorkTask._(this._owner, this._cancelSelection, this._onCancel);
  final ImageWork _owner;
  final void Function()? _cancelSelection;
  final void Function()? _onCancel;
  final _done = Completer<void>();
  bool _cancelled = false;
  bool _selecting = false;

  bool get isCancelled => _cancelled;
  Future<void> get done => _done.future;

  void check() {
    if (_cancelled) throw const ImageWorkTaskCancelled();
  }

  Future<T> read<T>(Future<T> Function() action) async {
    check();
    final result = await action();
    check();
    return result;
  }

  Future<T> select<T>(Future<T> Function() action) async {
    _selecting = true;
    try {
      return await read(action);
    } finally {
      _selecting = false;
    }
  }

  void cancel() {
    if (_cancelled || _done.isCompleted) return;
    _cancelled = true;
    for (final callback in [if (_selecting) _cancelSelection, _onCancel]) {
      try {
        callback?.call();
      } catch (error, stack) {
        recordFailure(error, stack);
      }
    }
  }

  /// Retain errors that can no longer be delivered to their original UI.
  /// The returned acknowledgement removes this failure only if a drain has
  /// not already consumed it. An owner may use it after repairing the same
  /// idempotent assignment; existing observers still retain their own result.
  void Function() recordFailure(Object error, StackTrace stack) {
    if (error is ImageWorkTaskCancelled) return () {};
    final failure = _ReportedWorkFailure(error, stack);
    _owner._failures.add(failure);
    return () => _owner._failures.remove(failure);
  }

  void finish() {
    if (_done.isCompleted) return;
    _owner._tasks.remove(this);
    _done.complete();
  }
}

class _ReportedWorkFailure {
  _ReportedWorkFailure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

class ImageWorkTaskCancelled implements Exception {
  const ImageWorkTaskCancelled();
}

class ImageWorkFailure implements Exception {
  ImageWorkFailure(Iterable<({Object error, StackTrace stack})> failures)
    : failures = List.unmodifiable(failures);
  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image work failed: ${failures.map((failure) => failure.error).join('; ')}';
}
