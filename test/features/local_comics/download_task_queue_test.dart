import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'support/download_task_fixture.dart';

void main() {
  const sourceKey = 'download_task_test_source';

  setUp(() {
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().add(downloadFixtureSource(sourceKey));
    appdata.settings['downloadThreads'] = 1;
    appdata.settings['skipUnavailableDownloadImages'] = false;
  });

  tearDown(() {
    ComicSourceManager().remove(sourceKey);
    LocalManager.current?.dispose();
  });

  test(
    'restored downloads keep their owning queue and snapshot path',
    () async {
      final root = Directory.systemTemp.createTempSync('restored-owner-');
      final firstPath = Directory('${root.path}/first')..createSync();
      final secondPath = Directory('${root.path}/second')..createSync();
      LocalManager create() => LocalManager.independent(
        openDatabase: sqlite3.open,
        initializeSources: () async {},
      );
      final first = create();
      final second = create();
      addTearDown(() async {
        await first.pendingDownloadTaskWrites;
        await second.pendingDownloadTaskWrites;
        first.dispose();
        second.dispose();
        root.deleteSync(recursive: true);
      });
      final initial = ImagesDownloadTask(
        storage: first,
        source: ComicSource.find(sourceKey)!,
        comicId: 'restored',
      ).toJson();
      final firstFile = File('${firstPath.path}/downloading_tasks.json')
        ..writeAsStringSync(jsonEncode([initial]));
      final secondFile = File('${secondPath.path}/downloading_tasks.json')
        ..writeAsStringSync('[]');
      App.dataPath = firstPath.path;
      await first.init();
      App.dataPath = secondPath.path;
      await second.init();
      expect(first.downloadingTasks.single.id, 'restored');
      expect(second.downloadingTasks, isEmpty);
      // Restore again while the application global points at a different owner.
      first.restoreDownloadingTasks();
      final restored = first.downloadingTasks.single;
      restored.cancel();
      await restored.pendingCleanup;
      await first.pendingDownloadTaskWrites;
      expect(first.downloadingTasks, isEmpty);
      expect(jsonDecode(firstFile.readAsStringSync()), isEmpty);
      expect(secondFile.readAsStringSync(), '[]');
    },
  );

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
        storage: LocalManager(),
        source: ComicSource.find(sourceKey)!,
        comicId: 'comic-1',
      );
      manager.restorePausedDownloads([task]);
      final first = manager.saveCurrentDownloadingTasks();
      manager.restorePausedDownloads([]);
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
        storage: LocalManager(),
        source: ComicSource.find(sourceKey)!,
        comicId: 'existing',
      );
      final restored = ImagesDownloadTask(
        storage: LocalManager(),
        source: ComicSource.find(sourceKey)!,
        comicId: 'restored',
      );
      manager.restorePausedDownloads([existing]);
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
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      addTearDown(() async {
        await manager.pendingDownloadTaskWrites;
        db.dispose();
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      final first = CompletionQueueTask('one');
      final next = CompletionQueueTask('two');
      manager.restorePausedDownloads([first, next]);
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
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      final task = ImagesDownloadTask.fromJson(LocalManager(), {
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
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      manager.restorePausedDownloads([task]);
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

  test(
    'snapshot failure becomes retryable error and late failure preserves pause',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'download-snapshot-error-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final blocker = Directory('${root.path}/downloading_tasks.json')
        ..createSync();
      final task = ImagesDownloadTask.fromJson(LocalManager(), {
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
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      manager.restorePausedDownloads([task]);
      task.resume();
      await task.debugResumeFuture;
      expect(task.isError, isTrue);
      expect(task.isPaused, isTrue);
      expect(task.timer, isNull);
      expect(manager.downloadingTasks, [task]);
      expect(manager.count, 0);

      task.resume();
      task.pause();
      await task.debugResumeFuture;
      expect(task.isError, isFalse);
      expect(task.isPaused, isTrue);
      expect(task.timer, isNull);

      blocker.deleteSync();
      task.resume();
      await task.debugResumeFuture;
      await manager.pendingDownloadTaskWrites;
      expect(task.isError, isFalse);
      expect(task.timer, isNull);
      expect(manager.downloadingTasks, isEmpty);
      expect(manager.find(task.id, task.comicType), isNotNull);
    },
  );
}
