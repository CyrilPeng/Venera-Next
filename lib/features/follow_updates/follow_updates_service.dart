import 'dart:async';
import 'follow_update_task.dart';

/// Background checks own their task and never cancel unrelated foreground work.
class FollowUpdatesService {
  FollowUpdatesService({
    required this.folder,
    required this.isChecking,
    required this.waitForDownload,
    required this.createTask,
    required this.onUpdated,
    required this.onError,
  });
  final String? Function() folder;
  final bool Function() isChecking;
  final Future<void> Function() waitForDownload;
  final FollowUpdateTask Function(String folder) createTask;
  final void Function() onUpdated;
  final void Function(Object error, StackTrace stack) onError;
  Timer? _timer;
  _Check? _active;
  final _ownedChecks = <_Check>{};
  bool _running = false;
  bool _closed = false;
  Future<void>? _closeFuture;
  int _generation = 0;
  bool _exitHeld = false;
  int _exitGeneration = 0;
  Future<void Function()>? _exitPreparation;
  bool get isRunning => _running && !_exitHeld;
  bool get isPreparingForExit => _exitHeld;

  void start() {
    if (_closed) throw StateError('Follow updates service is closed');
    if (_running || _exitHeld) return;
    _running = true;
    _scheduleChecks();
  }

  void _scheduleChecks() {
    final generation = ++_generation;
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (isRunning && generation == _generation) unawaited(check());
    });
    unawaited(check());
  }

  Future<void> check() {
    if (!isRunning) return Future.value();
    if (_active != null) return _active!.future;
    if (isChecking()) return Future.value();
    final selected = folder();
    if (selected == null || !isRunning) return Future.value();
    final run = _Check();
    _active = run;
    _ownedChecks.add(run);
    unawaited(
      _check(run, selected).then<void>(
        (_) {
          _ownedChecks.remove(run);
          run.completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          _ownedChecks.remove(run);
          run.completion.completeError(error, stack);
        },
      ),
    );
    return run.future;
  }

  Future<void> _check(_Check run, String selected) async {
    var updated = 0;
    try {
      // This owner observes the download; cancelling its wait must not cancel
      // or delay the separate sync owner's exit preparation.
      await Future.any([waitForDownload(), run.cancelledSignal.future]);
      if (run.cancelled || !isRunning || isChecking()) return;
      final task = createTask(selected);
      run.task = task;
      if (run.cancelled || !isRunning) {
        task.cancel();
      } else {
        run.subscription = task.updatedCounts.listen((count) {
          if (!run.cancelled && isRunning) updated = count;
        }, onError: run.recordError);
      }
    } catch (error, stack) {
      run.recordError(error, stack);
    } finally {
      // Cancelling a progress subscription does not join the task's writes or
      // final notifications. Retain ownership until its actual execution ends.
      try {
        await run.task?.done;
      } catch (error, stack) {
        run.recordError(error, stack);
      }
      if (run.task != null && !run.cancelled && isRunning) {
        // Deliver progress queued before done, without requiring the event
        // stream itself to close. Later events are outside the task lifetime.
        await Future<void>.delayed(Duration.zero);
      }
      try {
        await run.cancelProgress();
      } catch (error, stack) {
        run.recordError(error, stack);
      }
      if (identical(_active, run)) _active = null;
      if (!run.cancelled && isRunning) {
        final failure = run.failure;
        if (failure != null) onError(failure.error, failure.stack);
        if (updated > 0) onUpdated();
      }
    }
  }

  void cancelChecking() {
    final run = _active;
    _active = null;
    if (run == null) return;
    _cancelCheck(run);
  }

  void _cancelCheck(_Check run) {
    run.cancelled = true;
    if (!run.cancelledSignal.isCompleted) run.cancelledSignal.complete();
    try {
      run.task?.cancel();
    } catch (error, stack) {
      run.recordError(error, stack);
      rethrow;
    } finally {
      run.cancelProgress().ignore();
    }
  }

  void stop() {
    _running = false;
    _stopScheduling();
    cancelChecking();
  }

  void _stopScheduling() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  /// Freeze new checks and join every check this owner accepted, including
  /// cancelled checks that a later start has already replaced.
  Future<void Function()> prepareForExit() {
    if (_closed) {
      return Future.error(StateError('Follow updates service is closed'));
    }
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final prepared = Completer<void Function()>();
    _exitPreparation = prepared.future;
    _exitHeld = true;
    final generation = ++_exitGeneration;
    _stopScheduling();
    void release() {
      if (!_exitHeld || generation != _exitGeneration) return;
      _exitHeld = false;
      _exitPreparation = null;
      if (_running) {
        try {
          _scheduleChecks();
        } catch (_) {
          stop();
          rethrow;
        }
      }
    }

    final checks = List.of(_ownedChecks);
    _active = null;
    ({Object error, StackTrace stack})? cancellationFailure;
    for (final check in checks) {
      try {
        _cancelCheck(check);
      } catch (error, stack) {
        cancellationFailure ??= (error: error, stack: stack);
      }
    }
    unawaited(
      _prepareForExit(
        checks,
        release,
        cancellationFailure,
      ).then<void>(prepared.complete, onError: prepared.completeError),
    );
    return prepared.future;
  }

  Future<void> closeAndWait() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    _closed = true;
    _running = false;
    _exitHeld = true;
    _exitGeneration++;
    _stopScheduling();
    final checks = List.of(_ownedChecks);
    _active = null;
    final failures = <({Object error, StackTrace stack})>[];
    for (final check in checks) {
      try {
        _cancelCheck(check);
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    return _closeFuture = _finishClose(checks, failures);
  }

  Future<void> _finishClose(
    List<_Check> checks,
    List<({Object error, StackTrace stack})> failures,
  ) async {
    await Future.wait(
      checks.map((check) async {
        try {
          await check.future;
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
        for (final failure in check.failures) {
          if (!failures.any((entry) => identical(entry.error, failure.error))) {
            failures.add(failure);
          }
        }
      }),
    );
    if (failures.isNotEmpty) throw FollowUpdatesCloseFailure(failures);
  }

  Future<void Function()> _prepareForExit(
    List<_Check> checks,
    void Function() release,
    ({Object error, StackTrace stack})? failure,
  ) async {
    try {
      // Future.wait joins the rest even if one check's callback fails.
      try {
        await Future.wait(checks.map((check) => check.future));
      } catch (error, stack) {
        failure ??= (error: error, stack: stack);
      }
      for (final check in checks) {
        failure ??= check.failure;
      }
      if (failure != null) {
        Error.throwWithStackTrace(failure.error, failure.stack);
      }
      return release;
    } catch (error, stack) {
      try {
        release();
      } catch (_) {
        // The preparation failure remains primary; release already cleared
        // the hold and stopped scheduling if restarting also failed.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
}

class FollowUpdatesCloseFailure implements Exception {
  FollowUpdatesCloseFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);
  final List<({Object error, StackTrace stack})> failures;
  @override
  String toString() =>
      'Follow updates shutdown failed: ${failures.map((failure) => failure.error).join('; ')}';
}

class _Check {
  _Check() {
    // Timer-started checks may have no caller. Explicit waiters still receive
    // callback failures, while exit preparation observes all owned checks.
    future.ignore();
  }

  bool cancelled = false;
  final cancelledSignal = Completer<void>();
  FollowUpdateTask? task;
  StreamSubscription<int>? subscription;
  Future<void>? _progressCancellation;
  final completion = Completer<void>();
  Future<void> get future => completion.future;
  final failures = <({Object error, StackTrace stack})>[];
  ({Object error, StackTrace stack})? get failure =>
      failures.isEmpty ? null : failures.first;

  void recordError(Object error, StackTrace stack) {
    if (!failures.any((failure) => identical(failure.error, error))) {
      failures.add((error: error, stack: stack));
    }
  }

  Future<void> cancelProgress() {
    final current = subscription;
    if (current == null) return Future.value();
    return _progressCancellation ??= Future<void>.sync(current.cancel);
  }
}
