import 'dart:async';
import 'dart:math';

/// Runs [tasks] with a fixed concurrency limit and the existing batch
/// throttle formula: after every [throttleEvery] scheduled tasks, wait
/// `min(scheduledCount % 100 + 1, 10)` seconds before scheduling more.
Future<void> runThrottledTasks<T>(
  List<T> tasks, {
  required int concurrency,
  required int throttleEvery,
  Future<void> Function(Duration duration)? delay,
  required Future<void> Function(T task) run,
}) async {
  if (tasks.isEmpty || concurrency <= 0) {
    return;
  }
  final wait = delay ?? _defaultDelay;
  var nextIndex = 0;
  var throttleGate = Future<void>.value();
  var schedulingLock = Future<void>.value();

  Future<T?> takeNext() {
    final previousSchedule = schedulingLock;
    final releaseSchedule = Completer<void>();
    schedulingLock = releaseSchedule.future;
    return () async {
      await previousSchedule;
      try {
        await throttleGate;
        if (nextIndex >= tasks.length) {
          return null;
        }
        final task = tasks[nextIndex];
        nextIndex++;
        if (throttleEvery > 0 &&
            nextIndex < tasks.length &&
            nextIndex % throttleEvery == 0) {
          throttleGate = wait(_throttleDelay(nextIndex));
        }
        return task;
      } finally {
        releaseSchedule.complete();
      }
    }();
  }

  Future<void> worker() async {
    while (true) {
      final task = await takeNext();
      if (task == null) {
        return;
      }
      await run(task);
    }
  }

  final workerCount = min(concurrency, tasks.length);
  await Future.wait(List.generate(workerCount, (_) => worker()));
}

Duration _throttleDelay(int scheduledCount) {
  var delay = scheduledCount % 100 + 1;
  if (delay > 10) {
    delay = 10;
  }
  return Duration(seconds: delay);
}

Future<void> _defaultDelay(Duration duration) {
  return Future<void>.delayed(duration);
}
