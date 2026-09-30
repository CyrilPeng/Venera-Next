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
  bool _running = false;
  int _generation = 0;
  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    final generation = ++_generation;
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (_running && generation == _generation) unawaited(check());
    });
    unawaited(check());
  }

  Future<void> check() {
    if (!_running) return Future.value();
    if (_active != null) return _active!.future;
    if (isChecking()) return Future.value();
    final selected = folder();
    if (selected == null) return Future.value();
    final run = _Check();
    _active = run;
    return run.future = _check(run, selected);
  }

  Future<void> _check(_Check run, String selected) async {
    var updated = 0;
    try {
      await waitForDownload();
      if (run.cancelled || !_running || isChecking()) return;
      final task = createTask(selected);
      run.task = task;
      await for (final count in task.updatedCounts) {
        if (run.cancelled || !_running) return;
        updated = count;
      }
    } catch (error, stack) {
      if (!run.cancelled && _running) onError(error, stack);
    } finally {
      if (identical(_active, run)) _active = null;
      if (updated > 0 && !run.cancelled && _running) onUpdated();
    }
  }

  void cancelChecking() {
    final run = _active;
    _active = null;
    if (run == null) return;
    run.cancelled = true;
    run.task?.cancel();
  }

  void stop() {
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    cancelChecking();
  }
}

class _Check {
  bool cancelled = false;
  FollowUpdateTask? task;
  late Future<void> future;
}
