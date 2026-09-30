import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/follow_updates/follow_updates_api.dart';

class _Task implements FollowUpdateTask {
  final controller = StreamController<int>();
  int cancellations = 0;
  @override
  Stream<int> get updatedCounts => controller.stream;
  @override
  void cancel() {
    cancellations++;
  }
}

class _Fixture {
  final downloads = <Completer<void>>[];
  final tasks = <_Task>[];
  final errors = <Object>[];
  int notifications = 0;
  bool foregroundBusy = false;
  late final service = FollowUpdatesService(
    folder: () => 'folder',
    isChecking: () => foregroundBusy,
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
    onUpdated: () => notifications++,
    onError: (error, stack) => errors.add(error),
  );
  Future<void> finish() async {
    service.stop();
    for (final gate in downloads) {
      if (!gate.isCompleted) gate.complete();
    }
    for (final task in tasks) {
      await task.controller.close();
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
      await f.tasks.single.controller.close();
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
      await old.controller.close();
      await oldCheck;
      expect(f.notifications, 0);
      expect(current.cancellations, 0);
      current.controller.add(1);
      await current.controller.close();
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
    await f.tasks.single.controller.close();
    await retried;
    expect(f.notifications, 0);
  });
}
