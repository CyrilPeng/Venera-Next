import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/network/images.dart';

void main() {
  const sourceKey = 'download_task_test_source';

  setUp(() {
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().add(_testSource(sourceKey));
    appdata.settings['downloadThreads'] = 1;
  });

  tearDown(() {
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    ComicSourceManager().remove(sourceKey);
    LocalManager().downloadingTasks.clear();
    LocalManager.resetForTesting();
  });

  test('ImagesDownloadTask pause cancels active image stream', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-download-data-',
    );
    final cacheDir = Directory.systemTemp.createTempSync(
      'venera-download-cache-',
    );
    final downloadDir = Directory.systemTemp.createTempSync(
      'venera-download-task-',
    );
    addTearDown(() {
      if (dataDir.existsSync()) {
        dataDir.deleteSync(recursive: true);
      }
      if (cacheDir.existsSync()) {
        cacheDir.deleteSync(recursive: true);
      }
      if (downloadDir.existsSync()) {
        downloadDir.deleteSync(recursive: true);
      }
    });

    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;

    final streamStarted = Completer<void>();
    final streamCanceled = Completer<void>();
    final controller = StreamController<ImageDownloadProgress>(
      onListen: () {
        if (!streamStarted.isCompleted) {
          streamStarted.complete();
        }
      },
      onCancel: () {
        if (!streamCanceled.isCompleted) {
          streamCanceled.complete();
        }
      },
    );
    addTearDown(() async {
      if (!controller.isClosed) {
        await controller.close();
      }
    });

    ImageDownloader.debugLoadComicImageUnwrapped =
        (imageKey, sourceKey, cid, eid) {
          return controller.stream;
        };

    final task = ImagesDownloadTask.fromJson({
      'type': 'ImagesDownloadTask',
      'source': sourceKey,
      'comicId': 'comic-1',
      'comic': {
        'title': 'Test Comic',
        'subtitle': '',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': null,
        'sourceKey': sourceKey,
        'comicId': 'comic-1',
      },
      'chapters': null,
      'path': downloadDir.path,
      'cover': 'cover.jpg',
      'images': {
        '': ['image-1'],
      },
      'downloadedCount': 0,
      'totalCount': 1,
      'index': 0,
      'chapter': 0,
    })!;

    task.resume();
    await streamStarted.future.timeout(const Duration(seconds: 1));
    controller.add(
      const ImageDownloadProgress(currentBytes: 8, totalBytes: 16),
    );
    await pumpEventQueue();

    task.pause();

    await streamCanceled.future.timeout(const Duration(seconds: 1));
    await task.debugResumeFuture!.timeout(const Duration(seconds: 1));

    expect(task.isPaused, isTrue);
    expect(task.isError, isFalse);
  });

  test('ImagesDownloadTask pause wakes retry delay', () async {
    final source = _testSource(
      sourceKey,
      loadComicInfo: (id) async {
        throw 'network unavailable';
      },
    );
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().add(source);

    final task = ImagesDownloadTask(source: source, comicId: 'comic-1');

    task.resume();
    await pumpEventQueue();

    task.pause();

    await task.debugResumeFuture!.timeout(const Duration(milliseconds: 500));
    expect(task.isPaused, isTrue);
    expect(task.isError, isFalse);
  });

  test('ImagesDownloadTask rejects unsupported image data', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-download-data-',
    );
    final cacheDir = Directory.systemTemp.createTempSync(
      'venera-download-cache-',
    );
    final downloadDir = Directory.systemTemp.createTempSync(
      'venera-download-task-',
    );
    addTearDown(() {
      if (dataDir.existsSync()) {
        dataDir.deleteSync(recursive: true);
      }
      if (cacheDir.existsSync()) {
        cacheDir.deleteSync(recursive: true);
      }
      if (downloadDir.existsSync()) {
        downloadDir.deleteSync(recursive: true);
      }
    });

    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
    ImageDownloader.debugLoadComicImageUnwrapped =
        (imageKey, sourceKey, cid, eid) => Stream.value(
          ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List.fromList([1]),
          ),
        );

    final task = ImagesDownloadTask.fromJson({
      'type': 'ImagesDownloadTask',
      'source': sourceKey,
      'comicId': 'comic-1',
      'comic': {
        'title': 'Test Comic',
        'subtitle': '',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': null,
        'sourceKey': sourceKey,
        'comicId': 'comic-1',
      },
      'chapters': null,
      'path': downloadDir.path,
      'cover': 'cover.jpg',
      'images': {
        '': ['image-1'],
      },
      'downloadedCount': 0,
      'totalCount': 1,
      'index': 0,
      'chapter': 0,
    })!;

    task.resume();
    await task.debugResumeFuture!.timeout(const Duration(seconds: 1));

    expect(task.isError, isTrue);
    expect(task.message, contains('Unsupported image data'));
    expect(
      File('${downloadDir.path}${Platform.pathSeparator}0.').existsSync(),
      isFalse,
    );
  });

  test(
    'download task saves preserve snapshot order and recover after failure',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-task-writes-',
      );
      final manager = LocalManager();
      addTearDown(() async {
        await manager.pendingDownloadTaskWrites;
        await dataDir.delete(recursive: true);
      });
      App.dataPath = '${dataDir.path}/missing';
      await expectLater(
        manager.saveCurrentDownloadingTasks(),
        throwsA(isA<FileSystemException>()),
      );
      App.dataPath = dataDir.path;
      final task = ImagesDownloadTask(
        source: ComicSource.find(sourceKey)!,
        comicId: 'comic-1',
      );
      manager.downloadingTasks.add(task);
      final first = manager.saveCurrentDownloadingTasks();
      manager.downloadingTasks.clear();
      final second = manager.saveCurrentDownloadingTasks();
      await first;
      await second;
      expect(
        jsonDecode(
          await File('${dataDir.path}/downloading_tasks.json').readAsString(),
        ),
        isEmpty,
      );
    },
  );

  test(
    'restoration publishes only complete snapshots and does not duplicate tasks',
    () async {
      final root = Directory.systemTemp.createTempSync('download-restore-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      final manager = LocalManager();
      addTearDown(() async {
        await manager.pendingDownloadTaskWrites;
        root.deleteSync(recursive: true);
      });
      final existing = ImagesDownloadTask(
        source: ComicSource.find(sourceKey)!,
        comicId: 'existing',
      );
      final restored = ImagesDownloadTask(
        source: ComicSource.find(sourceKey)!,
        comicId: 'restored',
      );
      manager.downloadingTasks.add(existing);
      final file = File('${root.path}/downloading_tasks.json');
      final invalid = jsonEncode([
        restored.toJson(),
        {'type': 'ImagesDownloadTask', 'source': 'missing'},
      ]);
      file.writeAsStringSync(invalid);
      manager.restoreDownloadingTasks();
      expect(manager.downloadingTasks, [existing]);
      expect(file.readAsStringSync(), invalid);
      file.writeAsStringSync(
        jsonEncode([
          restored.toJson(),
          {'type': 'unknown'},
        ]),
      );
      manager.restoreDownloadingTasks();
      manager.restoreDownloadingTasks();
      expect(manager.downloadingTasks.map((task) => task.id), ['restored']);
      expect(manager.downloadingTasks.single.isPaused, isTrue);
      file.writeAsStringSync('[]');
      manager.restoreDownloadingTasks();
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'completion commits before queue notification and advancing the next task',
    () async {
      final root = Directory.systemTemp.createTempSync('download-complete-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      addTearDown(() async {
        await manager.pendingDownloadTaskWrites;
        db.dispose();
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      });
      final first = _CompletionTask('one');
      final next = _CompletionTask('two');
      manager.downloadingTasks.addAll([first, next]);
      await manager.saveCurrentDownloadingTasks();
      final file = File('${root.path}/downloading_tasks.json');
      final original = file.readAsStringSync();
      var notifications = 0;
      manager.addListener(() {
        notifications++;
        expect(manager.find(first.id, first.comicType), isNotNull);
        expect(manager.downloadingTasks, [next]);
        expect(next.resumes, 0);
      });
      db.execute(
        "CREATE TRIGGER reject_completion BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(
        () => manager.completeTask(first),
        throwsA(isA<SqliteException>()),
      );
      await manager.pendingDownloadTaskWrites;
      expect(manager.downloadingTasks, [first, next]);
      expect(manager.count, 0);
      expect(db.select('SELECT * FROM natural_sort_migration'), isEmpty);
      expect(file.readAsStringSync(), original);
      expect(notifications, 0);
      expect(next.resumes, 0);
      db.execute('DROP TRIGGER reject_completion;');
      manager.completeTask(first);
      await manager.pendingDownloadTaskWrites;
      expect(notifications, 1);
      expect(next.resumes, 1);
      expect(jsonDecode(file.readAsStringSync()).single['id'], 'two');
    },
  );

  test(
    'image completion write failure stops recorder and retains a retryable task',
    () async {
      final root = Directory.systemTemp.createTempSync('image-complete-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      final task = ImagesDownloadTask.fromJson({
        'type': 'ImagesDownloadTask',
        'source': sourceKey,
        'comicId': 'finished',
        'comic': {
          'title': 'Finished',
          'subtitle': '',
          'cover': 'cover.jpg',
          'description': '',
          'tags': <String, List<String>>{},
          'chapters': null,
          'sourceKey': sourceKey,
          'comicId': 'finished',
        },
        'chapters': null,
        'path': root.path,
        'cover': 'cover.jpg',
        'images': {'': <String>[]},
        'downloadedCount': 0,
        'totalCount': 0,
        'index': 0,
        'chapter': 1,
      })!;
      addTearDown(() async {
        task.pause();
        await manager.pendingDownloadTaskWrites;
        db.dispose();
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      });
      manager.downloadingTasks.add(task);
      db.execute(
        "CREATE TRIGGER reject_completion BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      task.resume();
      await task.debugResumeFuture;
      expect(task.isError, isTrue);
      expect(task.isPaused, isTrue);
      expect(task.timer, isNull);
      expect(manager.downloadingTasks, [task]);
      expect(manager.count, 0);
      db.execute('DROP TRIGGER reject_completion;');
      task.resume();
      await task.debugResumeFuture;
      await manager.pendingDownloadTaskWrites;
      expect(task.isError, isFalse);
      expect(task.isPaused, isTrue);
      expect(task.timer, isNull);
      expect(manager.downloadingTasks, isEmpty);
      expect(manager.find(task.id, task.comicType), isNotNull);
    },
  );

  test('ImagesDownloadTask cancel before path stops speed recorder', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-download-data-',
    );
    final cacheDir = Directory.systemTemp.createTempSync(
      'venera-download-cache-',
    );
    addTearDown(() async {
      await LocalManager().pendingDownloadTaskWrites;
      if (dataDir.existsSync()) {
        await dataDir.delete(recursive: true);
      }
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
      }
    });

    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;

    final source = ComicSource.find(sourceKey)!;
    final task = ImagesDownloadTask(source: source, comicId: 'comic-1');
    LocalManager().downloadingTasks.add(task);

    task.runRecorder();
    expect(task.timer, isNotNull);

    task.cancel();
    await LocalManager().pendingDownloadTaskWrites;

    expect(task.timer, isNull);
    expect(LocalManager().downloadingTasks, isNot(contains(task)));
  });
}

ComicSource _testSource(String key, {LoadComicFunc? loadComicInfo}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    null,
    '',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

class _CompletionTask extends DownloadTask {
  _CompletionTask(this.id);
  @override
  final String id;
  int resumes = 0;
  @override
  ComicType get comicType => const ComicType(17);
  @override
  String get title => id;
  @override
  String? get cover => null;
  @override
  String get message => '';
  @override
  bool get isError => false;
  @override
  bool get isPaused => true;
  @override
  double get progress => 1;
  @override
  int get speed => 0;
  @override
  void cancel() {}
  @override
  void pause() {}
  @override
  void resume() => resumes++;
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
