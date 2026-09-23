import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/follow_updates/follow_update_queue.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  testWidgets('100 instant checks have source spacing without batch pauses', (
    tester,
  ) async {
    final clock = tester.binding.clock;
    final start = clock.now();
    final scope = RequestScope();
    Duration? finished;
    runFollowUpdateTasks(
      List.generate(100, (i) => i),
      sourceKey: (_) => 'same',
      run: (_) async {},
      scope: scope,
      now: clock.now,
    ).then((_) => finished = clock.now().difference(start));
    await tester.pump();
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(finished, const Duration(milliseconds: 49500));
    scope.dispose();
  });

  test(
    'slow sources do not monopolize slots and limits are respected',
    () async {
      final scope = RequestScope();
      final started = <String>[];
      final blockers = <Completer<void>>[];
      final tasks = ['a', 'a', 'a', 'a', 'a', 'b', 'c', 'd', 'e'];
      final result = runFollowUpdateTasks(
        tasks,
        sourceKey: (key) => key,
        scope: scope,
        sourceInterval: Duration.zero,
        run: (key) async {
          started.add(key);
          final blocker = Completer<void>();
          blockers.add(blocker);
          await scope.run(() => blocker.future);
        },
      );
      final assertion = expectLater(result, throwsA(isA<RequestCancelled>()));
      await pumpEventQueue();
      expect(started, ['a', 'a', 'b', 'c', 'd']);
      scope.cancel();
      await assertion;
      expect(started, hasLength(5));
      scope.dispose();
    },
  );
}
