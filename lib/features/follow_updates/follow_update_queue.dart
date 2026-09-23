import 'dart:async';

import 'package:venera_next/network/request_scope.dart';

/// Keep unrelated sources moving while spacing requests to the same source.
Future<void> runFollowUpdateTasks<T>(
  List<T> tasks, {
  required String Function(T) sourceKey,
  required Future<void> Function(T) run,
  required RequestScope scope,
  int concurrency = 5,
  int perSourceConcurrency = 2,
  Duration sourceInterval = const Duration(milliseconds: 500),
  DateTime Function()? now,
}) async {
  if (concurrency < 1 || perSourceConcurrency < 1) {
    throw ArgumentError('Invalid concurrency');
  }
  final clock = now ?? DateTime.now;
  final pending = List<T>.of(tasks);
  final active = <String, int>{};
  final nextStart = <String, DateTime>{};
  final running = <Future<void>>{};
  var changed = Completer<void>();
  try {
    while (pending.isNotEmpty || running.isNotEmpty) {
      scope.check();
      final now = clock();
      Duration? delay;
      for (var i = 0; i < pending.length && running.length < concurrency;) {
        final task = pending[i];
        final key = sourceKey(task);
        if ((active[key] ?? 0) >= perSourceConcurrency) {
          i++;
          continue;
        }
        final wait = nextStart[key]?.difference(now) ?? Duration.zero;
        if (wait > Duration.zero) {
          if (delay == null || wait < delay) delay = wait;
          i++;
          continue;
        }
        pending.removeAt(i);
        active[key] = (active[key] ?? 0) + 1;
        nextStart[key] = now.add(sourceInterval);
        late Future<void> future;
        future = scope
            .run(() => run(task))
            .catchError((Object error) {
              scope.cancel(error);
            })
            .whenComplete(() {
              active[key] = active[key]! - 1;
              running.remove(future);
              if (!changed.isCompleted) changed.complete();
            });
        running.add(future);
      }
      if (pending.isEmpty && running.isEmpty) break;
      Timer? timer;
      if (running.length < concurrency && delay != null) {
        timer = Timer(delay, () {
          if (!changed.isCompleted) changed.complete();
        });
      }
      try {
        await scope.run(() => changed.future);
      } finally {
        timer?.cancel();
      }
      changed = Completer<void>();
    }
  } finally {
    await Future.wait(running);
  }
}
