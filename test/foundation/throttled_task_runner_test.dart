import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';

void main() {
  for (final duringThrottle in [false, true]) {
    test(
      'cancellation stops new tasks and drains in-flight work; throttle=$duringThrottle',
      () async {
        var cancelled = false;
        final gate = Completer<void>();
        final started = <int>[];
        final pending = runThrottledTasks(
          [1, 2, 3],
          concurrency: 2,
          throttleEvery: duringThrottle ? 1 : 0,
          delay: (_) => gate.future,
          isCancelled: () => cancelled,
          run: (value) async {
            started.add(value);
            if (!duringThrottle) await gate.future;
          },
        );
        await pumpEventQueue();
        expect(started, duringThrottle ? [1] : [1, 2]);
        cancelled = true;
        gate.complete();
        await pending;
        expect(started, duringThrottle ? [1] : [1, 2]);
      },
    );
  }

  test('runThrottledTasks limits concurrency and throttles batches', () async {
    final started = <int>[];
    final completed = <int>[];
    final delays = <Duration>[];
    final blockers = <Completer<void>>[];
    var active = 0;
    var maxActive = 0;

    final runFuture = runThrottledTasks<int>(
      List.generate(6, (index) => index),
      concurrency: 3,
      throttleEvery: 3,
      delay: (duration) {
        delays.add(duration);
        return Future<void>.value();
      },
      run: (task) async {
        started.add(task);
        active++;
        if (active > maxActive) {
          maxActive = active;
        }
        final blocker = Completer<void>();
        blockers.add(blocker);
        await blocker.future;
        active--;
        completed.add(task);
      },
    );

    await pumpEventQueue();

    expect(started, [0, 1, 2]);
    expect(delays, [const Duration(seconds: 4)]);
    expect(maxActive, 3);

    for (final blocker in blockers.take(3)) {
      blocker.complete();
    }
    await pumpEventQueue();

    expect(started, [0, 1, 2, 3, 4, 5]);
    expect(delays, [const Duration(seconds: 4)]);
    expect(maxActive, 3);

    for (final blocker in blockers.skip(3)) {
      blocker.complete();
    }
    await runFuture;

    expect(completed, hasLength(6));
    expect(maxActive, 3);
  });

  test('runThrottledTasks does not wait after final throttled batch', () async {
    final finalDelay = Completer<void>();
    var delayCount = 0;

    await runThrottledTasks<int>(
      [0, 1, 2],
      concurrency: 3,
      throttleEvery: 3,
      delay: (duration) {
        delayCount++;
        return finalDelay.future;
      },
      run: (_) async {},
    ).timeout(const Duration(milliseconds: 500));

    expect(delayCount, 0);
  });
}
