import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/follow_updates/follow_updates_api.dart';

class _Fixture {
  final observers = <void Function()>[];
  final downloads = <Completer<void>>[];
  final tasks = <_Task>[];
  bool failSubscription = false;
  bool failFolder = false;
  int releases = 0;
  late final runtime = FollowUpdatesRuntime(
    folder: () {
      if (failFolder) throw StateError('folder');
      return 'following';
    },
    isChecking: () => false,
    waitForDownload: () {
      final gate = Completer<void>();
      downloads.add(gate);
      return gate.future;
    },
    createTask: (_) {
      final task = _Task();
      tasks.add(task);
      return task;
    },
    onError: (error, _) => fail('Unexpected error: $error'),
    observeChanges: (changed) {
      if (failSubscription) throw StateError('subscription');
      observers.add(changed);
      return () {
        releases++;
        observers.remove(changed);
      };
    },
  );

  Future<void> finish() async {
    runtime.dispose();
    for (final gate in downloads) {
      if (!gate.isCompleted) gate.complete();
    }
    await pumpEventQueue();
    for (final task in tasks) {
      await task.stream.close();
    }
  }
}

class _Task implements FollowUpdateTask {
  final stream = StreamController<int>();
  int cancellations = 0;
  @override
  Stream<int> get updatedCounts => stream.stream;
  @override
  void cancel() => cancellations++;
}

void main() {
  test(
    'owners isolate notifications, download waits and subscriptions',
    () async {
      final first = _Fixture();
      final second = _Fixture();
      addTearDown(first.finish);
      addTearDown(second.finish);
      first.runtime.start();
      first.runtime.start();
      second.runtime.start();
      expect(first.observers, hasLength(1));
      expect(first.downloads, hasLength(1));
      first.observers.single();
      expect(first.runtime.changes.value, 1);
      expect(second.runtime.changes.value, 0);
      first.runtime.stop();
      expect(first.observers, isEmpty);
      expect(second.observers, hasLength(1));
      first.downloads.single.complete();
      second.downloads.single.complete();
      await pumpEventQueue();
      expect(first.tasks, isEmpty);
      expect(second.tasks, hasLength(1));
      second.runtime.dispose();
      expect(second.tasks.single.cancellations, 1);
      expect(second.observers, isEmpty);
      expect(second.runtime.start, throwsStateError);
    },
  );

  for (final subscriptionFailure in [false, true]) {
    test(
      'failed start releases resources and can retry: $subscriptionFailure',
      () async {
        final fixture = _Fixture()
          ..failSubscription = subscriptionFailure
          ..failFolder = !subscriptionFailure;
        addTearDown(fixture.finish);
        expect(fixture.runtime.start, throwsStateError);
        expect(fixture.runtime.isRunning, isFalse);
        expect(fixture.observers, isEmpty);
        fixture.failSubscription = false;
        fixture.failFolder = false;
        fixture.runtime.start();
        expect(fixture.observers, hasLength(1));
        expect(fixture.downloads, hasLength(1));
        fixture.runtime.stop();
        fixture.runtime.stop();
        expect(fixture.releases, subscriptionFailure ? 1 : 2);
      },
    );
  }

  test(
    'stopped download cannot create work after the owner restarts',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      fixture.runtime.stop();
      fixture.runtime.start();
      fixture.downloads.first.complete();
      await pumpEventQueue();
      expect(fixture.tasks, isEmpty);
      fixture.downloads.last.complete();
      await pumpEventQueue();
      fixture.tasks.single.stream.add(2);
      await fixture.tasks.single.stream.close();
      await pumpEventQueue();
      expect(fixture.runtime.changes.value, 1);
      expect(fixture.releases, 1);
    },
  );
}
