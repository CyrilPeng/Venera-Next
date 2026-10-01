import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/download_queue.dart';
import 'package:venera_next/features/local_comics/download_task.dart';
import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late List<String> events;
  late DownloadQueue queue;
  late bool failCommit;
  setUp(() {
    events = [];
    failCommit = false;
    queue = DownloadQueue(
      commitComic: (comic) {
        events.add('commit:${comic.id}');
        if (failCommit) throw StateError('injected');
      },
      notifyChanged: () => events.add('notify'),
      requestSave: () => events.add('save'),
    );
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
    () {
      final first = _Task('a', events);
      final second = _Task('b', events);
      queue.moveToFirst(first);
      expect(events, isEmpty);
      queue.add(first);
      queue.add(second);
      events.clear();
      queue.moveToFirst(second);
      expect(queue.tasks, [second, first]);
      expect(events, ['pause:a', 'notify', 'save', 'resume:b']);
      events.clear();
      queue.moveToFirst(second);
      queue.moveToFirst(_Task('b', events));
      expect(events, isEmpty);
      second.pause();
      events.clear();
      queue.moveToFirst(first);
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
  bool _paused = true;
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
  void cancel() => pause();
  @override
  void pause() {
    _paused = true;
    events.add('pause:$id');
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
