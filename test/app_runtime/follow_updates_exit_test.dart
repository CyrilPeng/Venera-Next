import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/follow_updates.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';

void main() {
  test(
    'combined preparation holds jobs and releases them before scheduling',
    () async {
      final runtimeReady = Completer<void Function()>();
      var runtimeReleases = 0;
      final runtime = _Runtime(() => runtimeReady.future);
      final preparing = prepareApplicationFollowUpdatesForExit(runtime);
      await pumpEventQueue();

      final refused = FollowUpdateJob('unused', false);
      expect(refused.isCancelled, isTrue);
      await refused.done;

      runtimeReady.complete(() {
        runtimeReleases++;
        final restarted = FollowUpdateJob('unused', false);
        expect(restarted.isCancelled, isFalse);
        restarted.cancel();
      });
      final release = await preparing;
      addTearDown(release);
      final stillRefused = FollowUpdateJob('unused', false);
      expect(stillRefused.isCancelled, isTrue);
      await stillRefused.done;
      release();
      release();
      expect(runtimeReleases, 1);
    },
  );

  for (final synchronous in [false, true]) {
    test(
      'runtime failure releases foreground admission; synchronous=$synchronous',
      () async {
        final error = StateError('runtime preparation failed');
        final runtime = _Runtime(() {
          if (synchronous) throw error;
          return Future.error(error);
        });
        await expectLater(
          prepareApplicationFollowUpdatesForExit(runtime),
          throwsA(same(error)),
        );
        final accepted = FollowUpdateJob('unused', false);
        expect(accepted.isCancelled, isFalse);
        accepted.cancel();
        await accepted.done;
      },
    );
  }
}

class _Runtime extends Fake implements FollowUpdatesRuntime {
  _Runtime(this.prepare);
  final Future<void Function()> Function() prepare;

  @override
  Future<void Function()> prepareForExit() => prepare();
}
