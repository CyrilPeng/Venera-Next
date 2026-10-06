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
      await task.finish();
    }
  }
}

class _Task implements FollowUpdateTask {
  _Task() {
    done.ignore();
  }

  final stream = StreamController<int>();
  final finished = Completer<void>();
  int cancellations = 0;
  @override
  Future<void> get done => finished.future;
  @override
  Stream<int> get updatedCounts => stream.stream;
  @override
  void cancel() => cancellations++;

  Future<void> finish() async {
    if (!finished.isCompleted) finished.complete();
    await stream.close();
  }
}

void main() {
  test('final close after dispose still joins the retired task', () async {
    final fixture = _Fixture();
    addTearDown(fixture.finish);
    fixture.runtime.start();
    fixture.downloads.single.complete();
    await pumpEventQueue();
    fixture.runtime.dispose();
    var closed = false;
    final closing = fixture.runtime.closeAndWait();
    expect(identical(closing, fixture.runtime.closeAndWait()), isTrue);
    final done = closing.then((_) => closed = true);
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(fixture.observers, isEmpty);
    await fixture.tasks.single.finish();
    await done;
    expect(fixture.runtime.start, throwsStateError);
    expect(fixture.releases, 1);
  });

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
      await fixture.tasks.single.finish();
      await pumpEventQueue();
      expect(fixture.runtime.changes.value, 1);
      expect(fixture.releases, 1);
    },
  );

  test(
    'exit retains final-change observation and freezes duplicate starts',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      fixture.downloads.single.complete();
      await pumpEventQueue();
      final task = fixture.tasks.single;
      final preparing = fixture.runtime.prepareForExit();
      expect(fixture.runtime.prepareForExit(), same(preparing));
      expect(fixture.runtime.isRunning, isFalse);
      expect(task.cancellations, 1);
      fixture.runtime.start();
      fixture.runtime.start();
      expect(fixture.observers, hasLength(1));
      expect(fixture.downloads, hasLength(1));
      fixture.observers.single();
      expect(fixture.runtime.changes.value, 1);
      var ready = false;
      unawaited(preparing.then((_) => ready = true));
      await task.stream.close();
      await pumpEventQueue();
      expect(ready, isFalse);
      task.finished.complete();
      final release = await preparing;
      release();
      release();
      expect(fixture.runtime.isRunning, isTrue);
      expect(fixture.observers, hasLength(1));
      expect(fixture.downloads, hasLength(2));
      expect(fixture.releases, 0);
    },
  );

  test(
    'disposing during preparation cannot be undone by its release',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      fixture.downloads.single.complete();
      await pumpEventQueue();
      final task = fixture.tasks.single;
      final preparing = fixture.runtime.prepareForExit();
      fixture.runtime.dispose();
      expect(fixture.observers, isEmpty);
      expect(fixture.releases, 1);
      expect(task.cancellations, 1);
      task.finished.complete();
      final release = await preparing;
      release();
      release();
      expect(fixture.runtime.isRunning, isFalse);
      expect(fixture.observers, isEmpty);
      expect(fixture.downloads, hasLength(1));
      expect(fixture.runtime.start, throwsStateError);
      await expectLater(fixture.runtime.prepareForExit(), throwsStateError);
    },
  );

  test(
    'stop while held suppresses restoration and later start remains usable',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      final preparing = fixture.runtime.prepareForExit();
      fixture.runtime.stop();
      fixture.runtime.start();
      final release = await preparing;
      expect(fixture.downloads.single.isCompleted, isFalse);
      release();
      expect(fixture.runtime.isRunning, isFalse);
      expect(fixture.observers, isEmpty);
      expect(fixture.releases, 1);
      fixture.runtime.start();
      expect(fixture.runtime.isRunning, isTrue);
      expect(fixture.observers, hasLength(1));
      expect(fixture.downloads, hasLength(2));
    },
  );

  test(
    'failed preparation restores the same subscription and can retry',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      fixture.downloads.single.complete();
      await pumpEventQueue();
      final task = fixture.tasks.single;
      final preparing = fixture.runtime.prepareForExit();
      final error = StateError('final writes failed');
      final checked = expectLater(preparing, throwsA(same(error)));
      task.finished.completeError(error);
      await checked;
      expect(fixture.runtime.isRunning, isTrue);
      expect(fixture.observers, hasLength(1));
      expect(fixture.releases, 0);
      expect(fixture.downloads, hasLength(2));
      final retried = fixture.runtime.prepareForExit();
      final release = await retried;
      release();
      expect(fixture.runtime.isRunning, isTrue);
      expect(fixture.observers, hasLength(1));
    },
  );

  test('old releases cannot unfreeze a later runtime preparation', () async {
    final fixture = _Fixture();
    addTearDown(fixture.finish);
    fixture.runtime.start();
    final first = await fixture.runtime.prepareForExit();
    first();
    final second = await fixture.runtime.prepareForExit();
    first();
    fixture.runtime.start();
    expect(fixture.runtime.isRunning, isFalse);
    expect(fixture.observers, hasLength(1));
    expect(fixture.downloads, hasLength(2));
    second();
    expect(fixture.runtime.isRunning, isTrue);
    expect(fixture.downloads, hasLength(3));
  });

  test(
    'failed restoration can restart without duplicating its subscription',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.finish);
      fixture.runtime.start();
      fixture.downloads.single.complete();
      await pumpEventQueue();
      final preparing = fixture.runtime.prepareForExit();
      final error = StateError('final writes failed');
      final checked = expectLater(preparing, throwsA(same(error)));
      fixture.failFolder = true;
      fixture.tasks.single.finished.completeError(error);
      await checked;
      expect(fixture.runtime.isRunning, isFalse);
      expect(fixture.observers, hasLength(1));
      fixture.failFolder = false;
      fixture.runtime.start();
      expect(fixture.runtime.isRunning, isTrue);
      expect(fixture.observers, hasLength(1));
      fixture.runtime.stop();
      expect(fixture.observers, isEmpty);
      expect(fixture.releases, 1);
    },
  );
}
