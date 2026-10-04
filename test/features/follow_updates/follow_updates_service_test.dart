import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/follow_updates/follow_updates_api.dart';

class _Task implements FollowUpdateTask {
  _Task({void Function(_Task)? onListen}) {
    controller = StreamController<int>(onListen: () => onListen?.call(this));
    done.ignore();
  }

  late final StreamController<int> controller;
  final finished = Completer<void>();
  Object? cancelError;
  int cancellations = 0;
  @override
  Future<void> get done => finished.future;
  @override
  Stream<int> get updatedCounts => controller.stream;
  @override
  void cancel() {
    cancellations++;
    final error = cancelError;
    if (error != null) throw error;
  }

  Future<void> finish() async {
    if (!finished.isCompleted) finished.complete();
    await controller.close();
  }
}

class _Fixture {
  final downloads = <Completer<void>>[];
  final tasks = <_Task>[];
  final errors = <Object>[];
  int notifications = 0;
  bool foregroundBusy = false;
  _Task Function()? taskFactory;
  late final service = FollowUpdatesService(
    folder: () => 'folder',
    isChecking: () => foregroundBusy,
    waitForDownload: () {
      final gate = Completer<void>();
      downloads.add(gate);
      return gate.future;
    },
    createTask: (_) {
      final task = taskFactory?.call() ?? _Task();
      tasks.add(task);
      return task;
    },
    onUpdated: () => notifications++,
    onError: (error, stack) => errors.add(error),
  );
  Future<void> finish() async {
    for (final task in tasks) {
      task.cancelError = null;
    }
    service.stop();
    for (final gate in downloads) {
      if (!gate.isCompleted) gate.complete();
    }
    for (final task in tasks) {
      await task.finish();
    }
  }
}

void main() {
  test(
    'checks deduplicate and wait for downloads before creating an owned task',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      f.service.start();
      final checking = f.service.check();
      expect(f.downloads, hasLength(1));
      expect(f.tasks, isEmpty);
      f.downloads.single.complete();
      await pumpEventQueue();
      expect(f.tasks, hasLength(1));
      f.tasks.single.controller.add(2);
      await f.tasks.single.finish();
      await checking;
      expect(f.notifications, 1);
    },
  );

  test(
    'stop during download wait cannot create or cancel foreground work',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      final checking = f.service.check();
      f.foregroundBusy = true;
      f.service.stop();
      f.downloads.single.complete();
      await checking;
      expect(f.tasks, isEmpty);
      expect(f.notifications, 0);
      expect(f.foregroundBusy, isTrue);
    },
  );

  test(
    'cancellation owns its task and old completion cannot notify after restart',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      final oldCheck = f.service.check();
      f.downloads.first.complete();
      await pumpEventQueue();
      final old = f.tasks.single;
      f.service.stop();
      expect(old.cancellations, 1);
      f.service.start();
      final newCheck = f.service.check();
      f.downloads.last.complete();
      await pumpEventQueue();
      final current = f.tasks.last;
      expect(current, isNot(same(old)));
      old.controller.add(10);
      await old.finish();
      await oldCheck;
      expect(f.notifications, 0);
      expect(current.cancellations, 0);
      current.controller.add(1);
      await current.finish();
      await newCheck;
      expect(f.notifications, 1);
    },
  );

  test('failures release the check and permit a subsequent retry', () async {
    final f = _Fixture();
    addTearDown(f.finish);
    f.service.start();
    final failed = f.service.check();
    f.downloads.first.completeError(StateError('download failed'));
    await failed;
    expect(f.errors, hasLength(1));
    final retried = f.service.check();
    f.downloads.last.complete();
    await pumpEventQueue();
    await f.tasks.single.finish();
    await retried;
    expect(f.notifications, 0);
  });

  test(
    'business completion ends a check even while progress stays open',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      final checking = f.service.check();
      f.downloads.single.complete();
      await pumpEventQueue();
      final task = f.tasks.single;
      task.controller.add(2);
      await pumpEventQueue();
      task.finished.complete();
      await checking;
      expect(task.controller.isClosed, isFalse);
      expect(task.controller.hasListener, isFalse);
      expect(f.notifications, 1);
    },
  );

  test(
    'closed progress does not complete a task with pending final writes',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      final checking = f.service.check();
      f.downloads.single.complete();
      await pumpEventQueue();
      final task = f.tasks.single;
      var completed = false;
      unawaited(checking.then((_) => completed = true));
      task.controller.add(2);
      await task.controller.close();
      await pumpEventQueue();
      expect(completed, isFalse);
      expect(f.notifications, 0);
      expect(f.service.check(), same(checking));
      task.finished.complete();
      await checking;
      expect(f.notifications, 1);
    },
  );

  test(
    'exit cancels only its download waits and observes their late failures',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      f.service.stop();
      f.service.start();
      expect(f.downloads, hasLength(2));
      final preparing = f.service.prepareForExit();
      expect(f.service.prepareForExit(), same(preparing));
      expect(f.service.isRunning, isFalse);
      f.service.start();
      await f.service.check();
      expect(f.downloads, hasLength(2));
      final release = await preparing;
      expect(f.downloads.every((gate) => !gate.isCompleted), isTrue);
      f.downloads.first.completeError(
        StateError('late unrelated sync failure'),
      );
      f.downloads.last.complete();
      await pumpEventQueue();
      expect(f.errors, isEmpty);
      expect(f.tasks, isEmpty);
      expect(f.service.isRunning, isFalse);
      release();
      release();
      expect(f.service.isRunning, isTrue);
      expect(f.downloads, hasLength(3));
    },
  );

  test(
    'an immediate task delivers its queued final count before observer cleanup',
    () async {
      final f = _Fixture()
        ..taskFactory = () => _Task(
          onListen: (task) {
            task.controller.add(0);
            task.controller.add(3);
            task.finished.complete();
          },
        );
      addTearDown(f.finish);
      f.service.start();
      final checking = f.service.check();
      f.downloads.single.complete();
      await checking;
      expect(f.notifications, 1);
      expect(f.tasks.single.controller.isClosed, isFalse);
      expect(f.tasks.single.controller.hasListener, isFalse);
    },
  );

  test(
    'exit joins replaced tasks after their progress was cancelled',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      f.downloads.first.complete();
      await pumpEventQueue();
      final old = f.tasks.single;
      f.service.stop();
      f.service.start();
      f.downloads.last.complete();
      await pumpEventQueue();
      final current = f.tasks.last;
      final preparing = f.service.prepareForExit();
      var ready = false;
      unawaited(preparing.then((_) => ready = true));
      expect(old.cancellations, 2);
      expect(current.cancellations, 1);
      await pumpEventQueue();
      expect(old.controller.hasListener, isFalse);
      expect(current.controller.hasListener, isFalse);
      expect(old.controller.isClosed, isFalse);
      current.finished.complete();
      await pumpEventQueue();
      expect(ready, isFalse);
      old.finished.complete();
      final release = await preparing;
      expect(f.notifications, 0);
      f.service.stop();
      release();
      expect(f.service.isRunning, isFalse);
      expect(f.downloads, hasLength(2));
    },
  );

  test(
    'exit retries cancellation of all owned tasks and joins before failing',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      f.downloads.first.complete();
      await pumpEventQueue();
      final old = f.tasks.single;
      final error = StateError('old cancellation failed');
      old.cancelError = error;
      expect(f.service.cancelChecking, throwsA(same(error)));
      unawaited(f.service.check());
      f.downloads.last.complete();
      await pumpEventQueue();
      final current = f.tasks.last;
      final preparing = f.service.prepareForExit();
      var failed = false;
      final checked = expectLater(
        preparing,
        throwsA(
          predicate((value) {
            failed = true;
            return identical(value, error);
          }),
        ),
      );
      expect(old.cancellations, 2);
      expect(current.cancellations, 1);
      old.finished.complete();
      await pumpEventQueue();
      expect(failed, isFalse);
      expect(f.service.isRunning, isFalse);
      current.finished.complete();
      await checked;
      expect(f.service.isRunning, isTrue);
      expect(f.downloads, hasLength(3));
      final retried = f.service.prepareForExit();
      f.downloads.last.complete();
      final release = await retried;
      f.service.stop();
      release();
    },
  );

  test(
    'task failure drains other owners and failed preparation permits retry',
    () async {
      final f = _Fixture();
      addTearDown(f.finish);
      f.service.start();
      f.downloads.first.complete();
      await pumpEventQueue();
      final old = f.tasks.single;
      f.service.stop();
      f.service.start();
      f.downloads.last.complete();
      await pumpEventQueue();
      final current = f.tasks.last;
      final error = StateError('final notification failed');
      final preparing = f.service.prepareForExit();
      var failed = false;
      final checked = expectLater(
        preparing,
        throwsA(
          predicate((value) {
            failed = true;
            return identical(value, error);
          }),
        ),
      );
      old.finished.completeError(error);
      await pumpEventQueue();
      expect(failed, isFalse);
      expect(f.service.isRunning, isFalse);
      current.finished.complete();
      await checked;
      expect(f.errors, isEmpty);
      expect(f.service.isRunning, isTrue);
      expect(f.downloads, hasLength(3));
      final retried = f.service.prepareForExit();
      f.downloads.last.complete();
      final release = await retried;
      f.service.stop();
      release();
    },
  );

  test('a stream and done error report the same failed task once', () async {
    final f = _Fixture();
    addTearDown(f.finish);
    f.service.start();
    final checking = f.service.check();
    f.downloads.single.complete();
    await pumpEventQueue();
    final task = f.tasks.single;
    final error = StateError('source failed');
    task.controller.addError(error);
    await pumpEventQueue();
    task.finished.completeError(error);
    await checking;
    expect(f.errors, [same(error)]);
    final release = await f.service.prepareForExit();
    f.service.stop();
    release();
  });

  test(
    'old and repeated releases cannot release another preparation',
    () async {
      final f = _Fixture()..foregroundBusy = true;
      addTearDown(f.finish);
      f.service.start();
      final oldRelease = await f.service.prepareForExit();
      oldRelease();
      final release = await f.service.prepareForExit();
      oldRelease();
      expect(f.service.isRunning, isFalse);
      f.service.start();
      await f.service.check();
      expect(f.downloads, isEmpty);
      release();
      expect(f.service.isRunning, isTrue);
      release();
      f.service.stop();
      final stoppedRelease = await f.service.prepareForExit();
      f.service.start();
      stoppedRelease();
      expect(f.service.isRunning, isFalse);
    },
  );

  testWidgets('exit stops the timer until its preparation is released', (
    tester,
  ) async {
    var reads = 0;
    final service = FollowUpdatesService(
      folder: () {
        reads++;
        return null;
      },
      isChecking: () => false,
      waitForDownload: () async {},
      createTask: (_) => throw StateError('No folder'),
      onUpdated: () {},
      onError: (_, _) {},
    );
    addTearDown(service.stop);
    service.start();
    expect(reads, 1);
    final release = await service.prepareForExit();
    await tester.pump(const Duration(minutes: 30));
    service.start();
    await service.check();
    expect(reads, 1);
    release();
    expect(reads, 2);
    await tester.pump(const Duration(minutes: 10));
    expect(reads, 3);
    service.stop();
  });
}
