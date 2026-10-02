import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_queue.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late List<String> events;
  late DownloadQueue queue;
  late bool failCommit;
  void Function()? onCommit;
  void Function()? onNotify;
  setUp(() {
    events = [];
    failCommit = false;
    onCommit = null;
    onNotify = null;
    queue = DownloadQueue(
      commitComic: (comic) {
        events.add('commit:${comic.id}');
        if (failCommit) throw StateError('injected');
        onCommit?.call();
      },
      notifyChanged: () {
        events.add('notify');
        onNotify?.call();
      },
      requestSave: () => events.add('save'),
      reportError: (error, stack) => events.add('error:$error'),
    );
  });

  test(
    'move publishes immediately but all automatic starts wait for cleanup',
    () async {
      final gate = Completer<void>();
      final first = _Task('a', events)..cleanup = gate.future;
      final target = _Task('b', events);
      queue.add(first);
      queue.add(target);
      events.clear();
      final moved = queue.moveToFirst(target);
      expect(queue.tasks.first, target);
      expect(events, ['pause:a', 'notify', 'save']);
      expect(() => queue.restorePausedTasks([]), throwsStateError);
      queue.add(_Task('c', events));
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      gate.complete();
      await moved;
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:b',
      ]);
    },
  );

  test(
    'overlapping moves retain running intent and wait for every old stop',
    () async {
      final gates = [Completer<void>(), Completer<void>()];
      final first = _Task('a', events)..cleanup = gates[0].future;
      final second = _Task('b', events)..cleanup = gates[1].future;
      final last = _Task('c', events);
      queue.add(first);
      queue.add(second);
      queue.add(last);
      events.clear();
      final moveSecond = queue.moveToFirst(second);
      final moveLast = queue.moveToFirst(last);
      gates[1].complete();
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      gates[0].complete();
      await Future.wait([moveSecond, moveLast]);
      await pumpEventQueue();
      expect(queue.tasks.first, last);
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:c',
      ]);
    },
  );

  for (final throwsDuringPause in [false, true]) {
    test(
      'failed stop prevents automatic start (pause throws: $throwsDuringPause)',
      () async {
        final gate = Completer<void>();
        final first = _Task('a', events);
        if (throwsDuringPause) {
          first.onPause = () => throw StateError('stop failed');
        } else {
          first.cleanup = gate.future;
        }
        final target = _Task('b', events);
        queue.add(first);
        queue.add(target);
        events.clear();
        final moved = queue.moveToFirst(target);
        final failed = expectLater(moved, throwsStateError);
        if (!throwsDuringPause) gate.completeError(StateError('stop failed'));
        await failed;
        await pumpEventQueue();
        expect(events.where((event) => event.startsWith('resume:')), isEmpty);
        expect(
          events.where((event) => event.startsWith('error:')),
          hasLength(1),
        );
        expect(queue.tasks.first, target);
      },
    );
  }

  test(
    'manual pause cancels pending start and manual resume respects prior stop',
    () async {
      final gate = Completer<void>();
      final first = _Task('a', events)..cleanup = gate.future;
      final second = _Task('b', events);
      queue.add(first);
      queue.add(second);
      events.clear();
      final moved = queue.moveToFirst(second);
      expect(queue.isResumePending, isTrue);
      final paused = queue.pause(second);
      expect(queue.isResumePending, isFalse);
      queue.resume(second);
      queue.resume(second);
      expect(queue.isResumePending, isTrue);
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      final canceledStart = queue.pause(second);
      gate.complete();
      await Future.wait([moved, paused, canceledStart]);
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      expect(queue.isResumePending, isFalse);
      queue.resume(second);
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:b',
      ]);
    },
  );

  test(
    'manual controls ignore stale instances and tasks outside the head',
    () async {
      final first = _Task('a', events);
      final second = _Task('b', events);
      queue.restorePausedTasks([first, second]);
      queue.resume(_Task('a', events));
      queue.resume(second);
      await queue.pause(_Task('a', events));
      await queue.pause(second);
      expect(events, isEmpty);
      queue.resume(first);
      expect(events, ['notify', 'resume:a']);
      events.clear();
      queue.resume(first);
      expect(events, isEmpty);
    },
  );

  test(
    'notification pause invalidates a manual start before it reaches the task',
    () async {
      final task = _Task('a', events);
      queue.restorePausedTasks([task]);
      Future<void>? paused;
      onNotify = () {
        onNotify = null;
        paused = queue.pause(task);
      };
      queue.resume(task);
      await paused;
      await pumpEventQueue();
      expect(task.isPaused, isTrue);
      expect(queue.isResumePending, isFalse);
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
    },
  );

  test(
    'failed stop clears pending-start state and notifies controls',
    () async {
      final gate = Completer<void>();
      final first = _Task('a', events)..cleanup = gate.future;
      final second = _Task('b', events);
      queue.add(first);
      queue.add(second);
      final moved = queue.moveToFirst(second);
      expect(queue.isResumePending, isTrue);
      events.clear();
      final failure = expectLater(moved, throwsStateError);
      gate.completeError(StateError('cannot stop'));
      await failure;
      await pumpEventQueue();
      expect(queue.isResumePending, isFalse);
      expect(events.where((event) => event == 'notify'), hasLength(1));
      expect(second.isPaused, isTrue);
    },
  );

  test(
    'cancel tracks cleanup assigned after removal and gates a replacement start',
    () async {
      final gate = Completer<void>();
      final first = _Task('a', events);
      final replacement = _Task('a', events);
      first.onCancel = () {
        queue.remove(first);
        queue.add(replacement);
        first.cleanup = gate.future;
      };
      queue.add(first);
      events.clear();
      final canceled = queue.cancel(first);
      expect(identical(queue.tasks.single, replacement), isTrue);
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      gate.complete();
      await canceled;
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:a',
      ]);
    },
  );

  test(
    'cancel retains no-auto-advance behavior and ignores stale or recursive requests',
    () async {
      final first = _Task('a', events);
      final next = _Task('b', events);
      var cancels = 0;
      first.onCancel = () {
        cancels++;
        queue.cancel(first);
      };
      queue.add(first);
      queue.add(next);
      events.clear();
      await queue.cancel(_Task('a', events));
      expect(events, isEmpty);
      await queue.cancel(first);
      await queue.cancel(first);
      expect(cancels, 1);
      expect(queue.tasks, [next]);
      expect(next.isPaused, isTrue);
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
    },
  );

  test(
    'canceling a tail retains pending head start but waits for its cleanup',
    () async {
      final gates = [Completer<void>(), Completer<void>()];
      final first = _Task('a', events)..cleanup = gates[0].future;
      final second = _Task('b', events);
      final tail = _Task('c', events)..cleanup = gates[1].future;
      queue.add(first);
      queue.add(second);
      queue.add(tail);
      events.clear();
      final moved = queue.moveToFirst(second);
      final canceled = queue.cancel(tail);
      gates[0].complete();
      await moved;
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), isEmpty);
      gates[1].complete();
      await canceled;
      await pumpEventQueue();
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:b',
      ]);
    },
  );

  test('cancel listener pause overrides an older pending start', () async {
    final gate = Completer<void>();
    final first = _Task('a', events)..cleanup = gate.future;
    final second = _Task('b', events);
    final tail = _Task('c', events);
    queue.add(first);
    queue.add(second);
    queue.add(tail);
    final moved = queue.moveToFirst(second);
    Future<void>? paused;
    tail.onCancel = () => paused = queue.pause(second);
    events.clear();
    final canceled = queue.cancel(tail);
    gate.complete();
    await Future.wait([moved, canceled, paused!]);
    await pumpEventQueue();
    expect(second.isPaused, isTrue);
    expect(events.where((event) => event.startsWith('resume:')), isEmpty);
  });

  test('task view rejects mutations but reflects service updates', () {
    final view = queue.tasks;
    final task = _Task('a', events);
    expect(() => view.add(task), throwsUnsupportedError);
    queue.add(task);
    expect(view, [task]);
    expect(() => view.clear(), throwsUnsupportedError);
    expect(() => view[0] = _Task('b', events), throwsUnsupportedError);
    queue.remove(task);
    expect(view, isEmpty);
  });

  test(
    'paused restoration is complete, silent and deduplicated by source identity',
    () {
      final first = _Task('a', events);
      final other = _Task('a', events, type: 18);
      queue.restorePausedTasks([first, _Task('a', events), other]);
      expect(queue.tasks, [first, other]);
      expect(identical(queue.tasks.first, first), isTrue);
      expect(events, isEmpty);
      Iterable<DownloadTask> broken() sync* {
        yield _Task('new', events);
        throw StateError('injected decode failure');
      }

      expect(() => queue.restorePausedTasks(broken()), throwsStateError);
      expect(queue.tasks, [first, other]);
      queue.restorePausedTasks(queue.tasks);
      expect(queue.tasks, [first, other]);
      queue.restorePausedTasks([]);
      expect(queue.tasks, isEmpty);
      expect(events, isEmpty);
    },
  );

  test(
    'restoration rejects active current or incoming tasks without changing state',
    () {
      final running = _Task('a', events);
      queue.add(running);
      events.clear();
      expect(() => queue.restorePausedTasks([]), throwsStateError);
      expect(queue.tasks, [running]);
      running.pause();
      final incoming = _Task('b', events)..resume();
      events.clear();
      expect(() => queue.restorePausedTasks([incoming]), throwsStateError);
      expect(queue.tasks, [running]);
      expect(events, isEmpty);
      incoming.pause();
      queue.restorePausedTasks([incoming]);
      expect(queue.tasks, [incoming]);
    },
  );

  test(
    'pause listener removing the target cannot remove another task or reinsert it',
    () async {
      final first = _Task('a', events);
      final target = _Task('b', events);
      final last = _Task('c', events);
      queue.add(first);
      queue.add(target);
      queue.add(last);
      first.onPause = () => queue.remove(target);
      events.clear();
      await queue.moveToFirst(target);
      expect(queue.tasks, [first, last]);
      expect(events, ['pause:a', 'notify', 'save']);
      expect(last.isPaused, isTrue);
    },
  );

  test(
    'nested notification mutation owns scheduling and outer add does not resume twice',
    () {
      final first = _Task('a', events);
      final second = _Task('b', events);
      onNotify = () {
        onNotify = null;
        queue.add(second);
      };
      queue.add(first);
      expect(queue.tasks, [first, second]);
      expect(events.where((event) => event.startsWith('resume:')), [
        'resume:a',
      ]);
    },
  );

  test(
    'completion recalculates task index after commit callback changes queue',
    () {
      final first = _Task('a', events);
      final target = _Task('b', events);
      final last = _Task('c', events);
      queue.add(first);
      queue.add(target);
      queue.add(last);
      onCommit = () => queue.remove(first);
      events.clear();
      queue.complete(target);
      expect(queue.tasks, [last]);
      expect(events, [
        'commit:b',
        'notify',
        'save',
        'notify',
        'save',
        'resume:c',
      ]);
    },
  );

  test('same task completion cannot recursively commit twice', () {
    final task = _Task('a', events);
    queue.add(task);
    onCommit = () => queue.complete(task);
    events.clear();
    queue.complete(task);
    expect(queue.tasks, isEmpty);
    expect(events, ['commit:a', 'notify', 'save']);
  });

  test(
    'add publishes before resuming head and rejects duplicate source identity',
    () {
      final first = _Task('a', events);
      queue.add(first);
      expect(events, ['notify', 'save', 'resume:a']);
      events.clear();
      queue.add(_Task('a', events));
      expect(events, isEmpty);
      expect(queue.tasks, [first]);
      queue.add(_Task('a', events, type: 18));
      expect(queue.tasks, hasLength(2));
      expect(queue.contains('a', const ComicType(17)), isTrue);
      expect(queue.contains('a', const ComicType(18)), isTrue);
      expect(queue.contains('a', const ComicType(19)), isFalse);
      expect(events, ['notify', 'save', 'resume:a']);
    },
  );

  test(
    'move preserves running or paused state and ignores missing or first task',
    () async {
      final first = _Task('a', events);
      final second = _Task('b', events);
      await queue.moveToFirst(first);
      expect(events, isEmpty);
      queue.add(first);
      queue.add(second);
      events.clear();
      await queue.moveToFirst(second);
      expect(queue.tasks, [second, first]);
      expect(events, ['pause:a', 'notify', 'save', 'resume:b']);
      events.clear();
      await queue.moveToFirst(second);
      await queue.moveToFirst(_Task('b', events));
      expect(events, isEmpty);
      second.pause();
      events.clear();
      await queue.moveToFirst(first);
      expect(queue.tasks, [first, second]);
      expect(events, ['pause:b', 'notify', 'save']);
      expect(first.isPaused, isTrue);
    },
  );

  test(
    'stale callbacks cannot remove replacement and failed commit permits retry',
    () {
      final obsolete = _Task('a', events);
      final replacement = _Task('a', events);
      final next = _Task('b', events);
      queue.add(obsolete);
      queue.remove(obsolete);
      queue.add(replacement);
      queue.add(next);
      events.clear();
      queue.complete(obsolete);
      queue.remove(obsolete);
      queue.moveToFirst(obsolete);
      expect(events, isEmpty);
      expect(identical(queue.tasks.first, replacement), isTrue);
      failCommit = true;
      expect(() => queue.complete(replacement), throwsStateError);
      expect(events, ['commit:a']);
      expect(identical(queue.tasks.first, replacement), isTrue);
      failCommit = false;
      events.clear();
      queue.complete(replacement);
      expect(queue.tasks, [next]);
      expect(events, ['commit:a', 'notify', 'save', 'resume:b']);
      events.clear();
      queue.complete(replacement);
      expect(events, isEmpty);
    },
  );
}

class _Task extends DownloadTask {
  _Task(this.id, this.events, {int type = 17}) : comicType = ComicType(type);
  final List<String> events;
  @override
  final String id;
  @override
  final ComicType comicType;
  Future<void>? cleanup;
  @override
  Future<void> get pendingCleanup => cleanup ?? Future.value();
  bool _paused = true;
  void Function()? onPause;
  void Function()? onCancel;
  @override
  bool get isPaused => _paused;
  @override
  bool get isError => false;
  @override
  double get progress => 1;
  @override
  int get speed => 0;
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  void cancel() {
    pause();
    onCancel?.call();
  }

  @override
  void pause() {
    _paused = true;
    events.add('pause:$id');
    onPause?.call();
  }

  @override
  void resume() {
    _paused = false;
    events.add('resume:$id');
  }

  @override
  Map<String, dynamic> toJson() => {'id': id};
  @override
  LocalComic toLocalComic() => LocalComic(
    id: id,
    title: id,
    subtitle: '',
    tags: [],
    directory: id,
    chapters: null,
    cover: '',
    comicType: comicType,
    downloadedChapters: [],
    createdAt: DateTime(2026),
  );
}
