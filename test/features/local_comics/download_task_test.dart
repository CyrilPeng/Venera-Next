import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/local_comics/download_directory_allocator.dart';
import 'package:venera_next/features/local_comics/download_task_storage.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/file_downloader.dart';

void main() {
  const sourceKey = 'download_task_test_source';

  setUp(() {
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().add(_testSource(sourceKey));
    appdata.settings['downloadThreads'] = 1;
  });

  tearDown(() {
    ComicSourceManager().remove(sourceKey);
    LocalManager.current?.dispose();
  });

  test(
    'image download retains its injected library across allocation',
    () async {
      final root = Directory.systemTemp.createTempSync('download-owner-');
      final storage = _TaskStorage(root.path);
      final allocated = Completer<void>();
      final release = Completer<void>();
      storage.afterAllocate = () async {
        allocated.complete();
        await release.future;
      };
      final task = ImagesDownloadTask(
        storage: storage,
        source: _testSource(sourceKey, loadComicPages: (_, _) async => Res([])),
        comicId: 'owned',
        comic: _archiveComic(sourceKey, id: 'owned'),
        loadThumbnail: (_, _) => Stream.value(
          ImageDownloadProgress(
            currentBytes: 3,
            totalBytes: 3,
            imageBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        task.pause();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        root.deleteSync(recursive: true);
      });
      task.resume();
      await allocated.future;
      expect(storage.completed, isEmpty);
      release.complete();
      await task.debugResumeFuture;
      expect(task.isError, isFalse);
      expect(storage.saves, 3);
      expect(storage.completed, [same(task)]);
      expect(storage.comic!.id, 'owned');
      expect(File('${task.path}/${storage.comic!.cover}').existsSync(), isTrue);
      task.cancel();
      await task.pendingCleanup;
      expect(storage.removed, [same(task)]);
      expect(Directory('${root.path}/output').existsSync(), isTrue);
    },
  );

  test(
    'archive download retains its library while extraction drains',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-owner-');
      App.cachePath = root.path;
      final storage = _TaskStorage(root.path);
      final extracting = Completer<void>();
      final release = Completer<void>();
      final task = ArchiveDownloadTask(
        'https://example.invalid/owned.zip',
        _archiveComic(sourceKey),
        storage: storage,
        createDownloader: (url, path) => _ArchiveDownloader(
          url,
          path,
          Stream.value(const DownloadingStatus(1, 1, 0, true)),
        ),
        extractArchive: (_, path) async {
          extracting.complete();
          await release.future;
          File('$path/cover.jpg').writeAsBytesSync([7]);
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        task.pause();
        await task.pendingCleanup;
        await task.pendingRun;
        root.deleteSync(recursive: true);
      });
      task.resume();
      await extracting.future;
      expect(storage.completed, isEmpty);
      release.complete();
      await task.pendingRun;
      expect(task.isError, isFalse);
      expect(storage.completed, [same(task)]);
      task.cancel();
      await task.pendingCleanup;
      expect(storage.removed, [same(task)]);
      expect(File('${root.path}/output/cover.jpg').readAsBytesSync(), [7]);
    },
  );

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

  for (final resumeAfterAllocation in [false, true]) {
    test(
      'image allocation drains before ${resumeAfterAllocation ? "resume" : "cancel"}',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'image-owned-allocation-',
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalManager(initializeSources: () async {});
        final manager = LocalManager();
        await manager.init();
        final allocated = Completer<DownloadDirectoryAllocation>();
        final release = Completer<void>();
        final thumbnailStarted = Completer<void>();
        final thumbnail = StreamController<ImageDownloadProgress>(
          onListen: () => thumbnailStarted.complete(),
        );
        var allocations = 0;
        final task = ImagesDownloadTask(
          storage: LocalManager(),
          source: ComicSource.find(sourceKey)!,
          comicId: 'owned',
          comic: _archiveComic(sourceKey, id: 'owned'),
          allocateDirectory: (id, type, title) async {
            allocations++;
            final output = await manager.allocateDownloadDirectory(
              id,
              type,
              title,
            );
            allocated.complete(output);
            await release.future;
            return output;
          },
          loadThumbnail: (url, source) => thumbnail.stream,
        );
        manager.restorePausedDownloads([task]);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          task.pause();
          await task.pendingCleanup;
          await task.debugResumeFuture;
          if (!thumbnailStarted.isCompleted) thumbnail.stream.listen((_) {});
          await thumbnail.close();
          await manager.pendingDownloadTaskWrites;
          LocalManager.current?.dispose();
          root.deleteSync(recursive: true);
        });
        task.resume();
        final output = await allocated.future.timeout(
          const Duration(seconds: 2),
        );
        expect(task.path, isNull);
        final oldRun = task.debugResumeFuture;
        if (resumeAfterAllocation) {
          task.pause();
          task.resume();
        } else {
          task.cancel();
        }
        var drained = false;
        final cleanup = task.pendingCleanup.then((_) => drained = true);
        await pumpEventQueue();
        expect(drained, isFalse);
        expect(output.directory.existsSync(), isTrue);
        expect(thumbnailStarted.isCompleted, isFalse);
        release.complete();
        await cleanup;
        await oldRun;
        if (resumeAfterAllocation) {
          await thumbnailStarted.future.timeout(const Duration(seconds: 2));
          expect(task.path, output.directory.path);
          expect(allocations, 1);
          task.cancel();
          await task.pendingCleanup;
          await task.debugResumeFuture;
        }
        expect(output.directory.existsSync(), isFalse);
        expect(task.path, isNull);
        expect(manager.downloadingTasks, isEmpty);
      },
    );
  }

  test(
    'image cancellation preserves supplied and restored output without matching ownership',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'image-borrowed-output-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      addTearDown(() async {
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      for (final restored in [false, true]) {
        final directory = Directory('${root.path}/external-$restored')
          ..createSync();
        final chapter = Directory('${directory.path}/new_a')..createSync();
        final file = File('${chapter.path}/keep.jpg')..writeAsBytesSync([7]);
        final task = restored
            ? _pendingImageTask(sourceKey, directory.path, chapters: ['new/a'])
            : (ImagesDownloadTask(
                storage: LocalManager(),
                source: ComicSource.find(sourceKey)!,
                comicId: 'external',
                comic: _archiveComic(sourceKey, id: 'external'),
                chapters: ['new/a'],
              )..path = directory.path);
        manager.restorePausedDownloads([task]);
        task.cancel();
        await task.pendingCleanup;
        expect(file.readAsBytesSync(), [7]);
        expect(manager.downloadingTasks, isEmpty);
        await manager.add(
          LocalComic(
            id: task.id,
            title: 'Registered elsewhere',
            subtitle: '',
            tags: [],
            directory: 'registered',
            chapters: const ComicChapters({'new/a': 'New'}),
            cover: '',
            comicType: task.comicType,
            downloadedChapters: [],
            createdAt: DateTime(2026),
          ),
        );
        manager.restorePausedDownloads([task]);
        task.cancel();
        await task.pendingCleanup;
        expect(file.readAsBytesSync(), [7]);
      }
    },
  );

  test(
    'late image cancellation retains newly allocated committed output',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'image-committed-output-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final source = _testSource(
        sourceKey,
        loadComicPages: (id, ep) async => Res(<String>[]),
      );
      final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);
      final task = ImagesDownloadTask(
        storage: LocalManager(),
        source: source,
        comicId: 'committed',
        comic: _archiveComic(sourceKey, id: 'committed'),
        loadThumbnail: (url, source) => Stream.value(
          ImageDownloadProgress(
            currentBytes: bytes.length,
            totalBytes: bytes.length,
            imageBytes: bytes,
          ),
        ),
      );
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        task.pause();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await task.debugResumeFuture;
      final comic = manager.find(task.id, task.comicType)!;
      final cover = File('${task.path}/${comic.cover}');
      task.cancel();
      await task.pendingCleanup;
      expect(cover.readAsBytesSync(), bytes);
      expect(manager.find(task.id, task.comicType), isNotNull);
      expect(task.isError, isFalse);
    },
  );

  for (final resumeAfterPause in [false, true]) {
    test(
      'thumbnail ${resumeAfterPause ? "resume" : "cancel"} drains cancellation and discards old bytes',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'thumbnail-lifecycle-',
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalManager(initializeSources: () async {});
        final manager = LocalManager();
        await manager.init();
        final started = Completer<void>();
        final cancelStarted = Completer<void>();
        final release = Completer<void>();
        final restarted = Completer<void>();
        var loads = 0;
        final first = StreamController<ImageDownloadProgress>(
          onListen: () => started.complete(),
          onCancel: () {
            cancelStarted.complete();
            return release.future;
          },
        );
        final second = StreamController<ImageDownloadProgress>(
          onListen: () => restarted.complete(),
        );
        final task = ImagesDownloadTask(
          storage: LocalManager(),
          source: ComicSource.find(sourceKey)!,
          comicId: 'thumbnail',
          comic: _archiveComic(sourceKey, id: 'thumbnail'),
          loadThumbnail: (url, source) =>
              ++loads == 1 ? first.stream : second.stream,
        );
        manager.restorePausedDownloads([task]);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          task.pause();
          await task.pendingCleanup;
          await task.debugResumeFuture;
          await first.close();
          if (loads < 2) second.stream.listen((_) {});
          await second.close();
          await manager.pendingDownloadTaskWrites;
          LocalManager.current?.dispose();
          root.deleteSync(recursive: true);
        });
        task.resume();
        await started.future.timeout(const Duration(seconds: 2));
        final output = Directory(task.path!);
        first.add(
          ImageDownloadProgress(
            currentBytes: 4,
            totalBytes: 4,
            imageBytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]),
          ),
        );
        await pumpEventQueue();
        final oldRun = task.debugResumeFuture;
        if (resumeAfterPause) {
          task.pause();
          task.resume();
        } else {
          task.cancel();
        }
        await cancelStarted.future.timeout(const Duration(seconds: 2));
        var cleaned = false;
        final cleanup = task.pendingCleanup.then((_) => cleaned = true);
        await pumpEventQueue();
        expect(cleaned, isFalse);
        expect(output.existsSync(), isTrue);
        expect(output.listSync(), isEmpty);
        expect(loads, 1);
        release.complete();
        await cleanup;
        await oldRun;
        if (resumeAfterPause) {
          await restarted.future.timeout(const Duration(seconds: 2));
          expect(loads, 2);
          expect(output.listSync(), isEmpty);
          task.cancel();
          await task.pendingCleanup;
        }
        expect(output.existsSync(), isFalse);
        expect(task.isError, isFalse);
      },
    );
  }

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

    Stream<ImageDownloadProgress> loadImage(
      String imageKey,
      String? sourceKey,
      String cid,
      String eid,
    ) {
      return controller.stream;
    }

    final task = ImagesDownloadTask.fromJson(LocalManager(), {
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
    }, loadImage: loadImage)!;

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

    final task = ImagesDownloadTask(
      storage: LocalManager(),
      source: source,
      comicId: 'comic-1',
    );

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
    Stream<ImageDownloadProgress> loadImage(
      String imageKey,
      String? sourceKey,
      String cid,
      String eid,
    ) => Stream.value(
      ImageDownloadProgress(
        currentBytes: 1,
        totalBytes: 1,
        imageBytes: Uint8List.fromList([1]),
      ),
    );

    final task = ImagesDownloadTask.fromJson(LocalManager(), {
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
    }, loadImage: loadImage)!;

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
      final first = _CompletionTask('one');
      final next = _CompletionTask('two');
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

  test(
    'late metadata failure from a paused run cannot stop a newer run',
    () async {
      final first = Completer<Res<ComicDetails>>();
      final second = Completer<Res<ComicDetails>>();
      var calls = 0;
      final source = _testSource(
        sourceKey,
        loadComicInfo: (id) {
          calls++;
          return calls == 1 ? first.future : second.future;
        },
      );
      final task = ImagesDownloadTask(
        storage: LocalManager(),
        source: source,
        comicId: 'one',
      );
      addTearDown(task.pause);
      task.resume();
      final obsolete = task.debugResumeFuture!;
      task.pause();
      task.resume();
      expect(calls, 2);
      first.complete(Res.error('obsolete request'));
      await obsolete;
      expect(task.isError, isFalse);
      expect(task.isPaused, isFalse);
      expect(task.timer, isNotNull);
      task.pause();
      second.complete(Res.error('paused request'));
      await task.debugResumeFuture;
      expect(task.isError, isFalse);
      expect(task.isPaused, isTrue);
      expect(task.timer, isNull);
    },
  );

  test(
    'paused chapter-list fetch cannot publish a partial list to a newer run',
    () async {
      final root = Directory.systemTemp.createTempSync('download-list-run-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      final results = [
        Completer<Res<List<String>>>(),
        Completer<Res<List<String>>>(),
      ];
      final started = [Completer<void>(), Completer<void>()];
      var calls = 0;
      ComicSourceManager().remove(sourceKey);
      ComicSourceManager().add(
        _testSource(
          sourceKey,
          loadComicPages: (id, ep) {
            final index = calls++;
            started[index].complete();
            return results[index].future;
          },
        ),
      );
      final task = ImagesDownloadTask.fromJson(LocalManager(), {
        'type': 'ImagesDownloadTask',
        'source': sourceKey,
        'comicId': 'one',
        'comic': {
          'title': 'One',
          'subtitle': '',
          'cover': 'cover.jpg',
          'description': '',
          'tags': <String, List<String>>{},
          'chapters': {'a': 'A'},
          'sourceKey': sourceKey,
          'comicId': 'one',
        },
        'chapters': null,
        'path': root.path,
        'cover': 'cover.jpg',
        'images': null,
        'downloadedCount': 0,
        'totalCount': 0,
        'index': 0,
        'chapter': 0,
      })!;
      addTearDown(() async {
        task.pause();
        for (final pending in results) {
          if (!pending.isCompleted) pending.complete(Res.error('test ended'));
        }
        await task.debugResumeFuture;
        await LocalManager().pendingDownloadTaskWrites;
        root.deleteSync(recursive: true);
      });
      task.resume();
      final obsolete = task.debugResumeFuture!;
      await started[0].future.timeout(const Duration(seconds: 2));
      task.pause();
      task.resume();
      await started[1].future.timeout(const Duration(seconds: 2));
      results[0].complete(Res(['obsolete-image']));
      await obsolete;
      expect(task.toJson()['images'], isNull);
      expect(task.isPaused, isFalse);
      task.pause();
      results[1].complete(Res(<String>[]));
      await task.debugResumeFuture;
      expect(task.toJson()['images'], isNull);
      expect(task.isError, isFalse);
    },
  );

  test(
    'resume waits for canceled image stream cleanup before starting again',
    () async {
      final root = Directory.systemTemp.createTempSync('download-drain-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      final started = [Completer<void>(), Completer<void>()];
      final cancelGate = Completer<void>();
      final controllers = [
        StreamController<ImageDownloadProgress>(
          onListen: () => started[0].complete(),
          onCancel: () => cancelGate.future,
        ),
        StreamController<ImageDownloadProgress>(
          onListen: () => started[1].complete(),
        ),
      ];
      var streams = 0;
      final task = _pendingImageTask(
        sourceKey,
        root.path,
        loadImage: (image, source, cid, eid) => controllers[streams++].stream,
      );
      addTearDown(() async {
        if (!cancelGate.isCompleted) cancelGate.complete();
        task.pause();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        await LocalManager().pendingDownloadTaskWrites;
        for (final controller in controllers) {
          await controller.close();
        }
        root.deleteSync(recursive: true);
      });
      task.resume();
      await started[0].future.timeout(const Duration(seconds: 2));
      task.pause();
      final oldRun = task.debugResumeFuture!;
      task.resume();
      await pumpEventQueue();
      expect(streams, 1);
      expect(task.timer, isNull);
      cancelGate.complete();
      await oldRun;
      await started[1].future.timeout(const Duration(seconds: 2));
      expect(streams, 2);
      task.pause();
      await task.pendingCleanup;
      await task.debugResumeFuture;
      expect(task.isError, isFalse);
    },
  );

  for (final registeredBeforeCancel in [false, true]) {
    test(
      'cancel preserves chapters registered during draining (existing: $registeredBeforeCancel)',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'download-late-register-',
        );
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalManager(initializeSources: () async {});
        final manager = LocalManager();
        await manager.init();
        late final StreamController<ImageDownloadProgress> controller;
        final task = _pendingImageTask(
          sourceKey,
          '${manager.path}/book',
          chapters: ['new/a'],
          loadImage: (image, source, cid, eid) => controller.stream,
        );
        LocalComic record(List<String> downloaded) => LocalComic(
          id: task.id,
          title: 'Book',
          subtitle: '',
          tags: [],
          directory: 'book',
          chapters: const ComicChapters({'new/a': 'New'}),
          cover: '',
          comicType: task.comicType,
          downloadedChapters: downloaded,
          createdAt: DateTime(2026),
        );
        if (registeredBeforeCancel) await manager.add(record([]));
        final chapter = Directory('${task.path}/new_a')
          ..createSync(recursive: true);
        final page = File('${chapter.path}/page.jpg')..writeAsBytesSync([3]);
        final started = Completer<void>();
        final release = Completer<void>();
        controller = StreamController<ImageDownloadProgress>(
          onListen: () => started.complete(),
          onCancel: () => release.future,
        );
        manager.restorePausedDownloads([task]);
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          task.pause();
          await task.pendingCleanup;
          await task.debugResumeFuture;
          await manager.pendingDownloadTaskWrites;
          await controller.close();
          LocalManager.current?.dispose();
          root.deleteSync(recursive: true);
        });
        task.resume();
        await started.future.timeout(const Duration(seconds: 2));
        task.cancel();
        await pumpEventQueue();
        await manager.add(record(['new/a']));
        release.complete();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        expect(page.readAsBytesSync(), [3]);
        expect(manager.find(task.id, task.comicType)!.downloadedChapters, [
          'new/a',
        ]);
        expect(manager.downloadingTasks, isEmpty);
      },
    );
  }

  test(
    'cancel drains transfers and removes only unfinished normalized chapters',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'download-cancel-chapters-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      late final StreamController<ImageDownloadProgress> controller;
      final task = _pendingImageTask(
        sourceKey,
        '${manager.path}/book',
        chapters: ['kept', 'shared:a', 'new/a', '..'],
        loadImage: (image, source, cid, eid) => controller.stream,
      );
      await manager.add(
        LocalComic(
          id: task.id,
          title: 'Book',
          subtitle: '',
          tags: [],
          directory: 'book',
          chapters: const ComicChapters({'kept': 'Kept', 'new/a': 'New'}),
          cover: '',
          comicType: task.comicType,
          downloadedChapters: ['kept', 'shared/a'],
          createdAt: DateTime(2026),
        ),
      );
      final kept = Directory('${task.path}/kept')..createSync(recursive: true);
      final unfinished = Directory('${task.path}/new_a')
        ..createSync(recursive: true);
      final retained = File('${kept.path}/page.jpg')..writeAsBytesSync([1]);
      final shared = Directory('${task.path}/shared_a')..createSync();
      final sharedFile = File('${shared.path}/page.jpg')..writeAsBytesSync([2]);
      final started = Completer<void>();
      final cancelGate = Completer<void>();
      controller = StreamController<ImageDownloadProgress>(
        onListen: () => started.complete(),
        onCancel: () => cancelGate.future,
      );
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        if (!cancelGate.isCompleted) cancelGate.complete();
        task.pause();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        await manager.pendingDownloadTaskWrites;
        await controller.close();
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await started.future.timeout(const Duration(seconds: 2));
      task.cancel();
      await pumpEventQueue();
      expect(unfinished.existsSync(), isTrue);
      expect(retained.existsSync(), isTrue);
      expect(sharedFile.existsSync(), isTrue);
      expect(manager.downloadingTasks, isEmpty);
      cancelGate.complete();
      await task.pendingCleanup;
      await task.debugResumeFuture;
      expect(unfinished.existsSync(), isFalse);
      expect(retained.existsSync(), isTrue);
      expect(sharedFile.existsSync(), isTrue);
      expect(manager.find(task.id, task.comicType)!.downloadedChapters, [
        'kept',
        'shared/a',
      ]);
    },
  );

  test(
    'archive resume drains stale extraction and ignores its late failure',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-generation-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final output = Directory('${manager.path}/archive')..createSync();
      final firstExtraction = Completer<void>();
      final extracting = Completer<void>();
      var transfers = 0;
      final transferPaths = <String>[];
      var extractions = 0;
      final task = ArchiveDownloadTask(
        'https://example.invalid/book.zip',
        _archiveComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) {
          transfers++;
          transferPaths.add(path);
          File(path).writeAsStringSync('zip');
          return _ArchiveDownloader(
            url,
            path,
            Stream.value(const DownloadingStatus(1, 1, 0, true)),
          );
        },
        extractArchive: (archive, path) async {
          extractions++;
          if (extractions == 1) {
            extracting.complete();
            await firstExtraction.future;
          }
          File('$path/cover.jpg').writeAsBytesSync([1]);
        },
      )..path = output.path;
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        if (!firstExtraction.isCompleted) firstExtraction.complete();
        task.pause();
        await task.pendingCleanup;
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await extracting.future.timeout(const Duration(seconds: 2));
      final previous = task.pendingRun;
      task.pause();
      task.resume();
      await pumpEventQueue();
      expect(transfers, 1);
      firstExtraction.completeError(StateError('obsolete extraction'));
      await previous;
      await task.pendingRun;
      await manager.pendingDownloadTaskWrites;
      expect(transfers, 2);
      expect(transferPaths[0], transferPaths[1]);
      expect(File(transferPaths[0]).parent.existsSync(), isFalse);
      expect(task.isError, isFalse);
      expect(task.isPaused, isTrue);
      expect(task.speed, 0);
      expect(manager.find(task.id, task.comicType), isNotNull);
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'archive cancellation waits for extraction before deleting its directory',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-cancel-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final gate = Completer<void>();
      String? archiveFilePath;
      final extracting = Completer<void>();
      final task = ArchiveDownloadTask(
        'https://example.invalid/book.zip',
        _archiveComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => _ArchiveDownloader(
          url,
          path,
          Stream.value(const DownloadingStatus(1, 1, 0, true)),
        ),
        extractArchive: (archive, path) async {
          archiveFilePath = archive;
          extracting.complete();
          await gate.future;
          File('$path/cover.jpg').writeAsBytesSync([1]);
        },
      );
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        task.pause();
        await task.pendingCleanup;
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await extracting.future.timeout(const Duration(seconds: 2));
      final output = Directory(task.path!);
      final canceled = manager.cancelDownload(task);
      await pumpEventQueue();
      expect(output.existsSync(), isTrue);
      expect(manager.downloadingTasks, isEmpty);
      final next = _CompletionTask('after-archive');
      manager.addTask(next);
      await pumpEventQueue();
      expect(next.resumes, 0);
      gate.complete();
      await canceled;
      await pumpEventQueue();
      expect(next.resumes, 1);
      expect(output.existsSync(), isFalse);
      expect(File(archiveFilePath!).parent.existsSync(), isFalse);
      expect(task.path, isNull);
      expect(task.isError, isFalse);
      expect(manager.count, 0);
    },
  );

  test(
    'archive transport failure is retryable and does not escape async void',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-error-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      final task = ArchiveDownloadTask(
        'https://example.invalid/book.zip',
        _archiveComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => _ArchiveDownloader(
          url,
          path,
          Stream.error(StateError('injected transport')),
        ),
      )..path = root.path;
      addTearDown(() async {
        task.pause();
        await task.pendingCleanup;
        root.deleteSync(recursive: true);
      });
      task.resume();
      await task.pendingRun;
      expect(task.isError, isTrue);
      expect(task.isPaused, isTrue);
      expect(task.speed, 0);
      task.resume();
      await task.pendingRun;
      expect(task.isError, isTrue);
      expect(task.isPaused, isTrue);
    },
  );

  test(
    'parallel archive tasks own different temporary files and clean only themselves',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-isolation-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final paths = <String, String>{};
      final started = [Completer<void>(), Completer<void>()];
      final gates = [Completer<void>(), Completer<void>()];
      ArchiveDownloadTask makeTask(int index) {
        final output = Directory('${manager.path}/archive-$index')
          ..createSync();
        return ArchiveDownloadTask(
          'https://example.invalid/$index.zip',
          _archiveComic(sourceKey, id: 'archive-$index'),
          storage: LocalManager(),
          createDownloader: (url, path) {
            paths['$index'] = path;
            File(path).writeAsStringSync('zip-$index');
            File('$path.download').writeAsStringSync('resume-$index');
            return _ArchiveDownloader(
              url,
              path,
              Stream.value(const DownloadingStatus(1, 1, 0, true)),
            );
          },
          extractArchive: (archive, outputPath) async {
            started[index].complete();
            await gates[index].future;
            expect(File(archive).readAsStringSync(), 'zip-$index');
            File('$outputPath/cover.jpg').writeAsBytesSync([1]);
          },
        )..path = output.path;
      }

      final tasks = [makeTask(0), makeTask(1)];
      manager.restorePausedDownloads(tasks);
      addTearDown(() async {
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        for (final task in tasks) {
          task.pause();
          await task.pendingCleanup;
        }
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      for (final task in tasks) {
        task.resume();
      }
      await Future.wait(
        started.map((started) => started.future),
      ).timeout(const Duration(seconds: 2));
      expect(paths['0'], isNot(paths['1']));
      gates[0].complete();
      await tasks[0].pendingRun;
      expect(File(paths['0']!).parent.existsSync(), isFalse);
      expect(File(paths['1']!).readAsStringSync(), 'zip-1');
      expect(File('${paths['1']}.download').existsSync(), isTrue);
      gates[1].complete();
      await tasks[1].pendingRun;
      expect(File(paths['1']!).parent.existsSync(), isFalse);
      expect(manager.count, 2);
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'archive cancellation preserves registered and externally supplied output',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-owned-output-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final existing = Directory('${manager.path}/existing')..createSync();
      final sentinel = File('${existing.path}/original.jpg')
        ..writeAsBytesSync([7]);
      final gate = Completer<void>();
      final extracting = Completer<void>();
      final task = ArchiveDownloadTask(
        'https://example.invalid/registered.zip',
        _archiveComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => _ArchiveDownloader(
          url,
          path,
          Stream.value(const DownloadingStatus(1, 1, 0, true)),
        ),
        extractArchive: (archive, path) async {
          extracting.complete();
          await gate.future;
        },
      );
      await manager.add(
        LocalComic(
          id: task.id,
          title: task.title,
          subtitle: '',
          tags: [],
          directory: 'existing',
          chapters: null,
          cover: 'original.jpg',
          comicType: task.comicType,
          downloadedChapters: [],
          createdAt: DateTime(2026),
        ),
      );
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        task.pause();
        await task.pendingCleanup;
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await extracting.future.timeout(const Duration(seconds: 2));
      task.cancel();
      gate.complete();
      await task.pendingCleanup;
      expect(sentinel.readAsBytesSync(), [7]);
      expect(manager.find(task.id, task.comicType), isNotNull);

      final external = Directory('${root.path}/external')..createSync();
      final borrowed = File('${external.path}/keep.txt')
        ..writeAsStringSync('keep');
      final supplied = ArchiveDownloadTask(
        'https://example.invalid/external.zip',
        _archiveComic(sourceKey, id: 'external'),
        storage: LocalManager(),
      )..path = external.path;
      manager.restorePausedDownloads([supplied]);
      supplied.cancel();
      await supplied.pendingCleanup;
      expect(borrowed.readAsStringSync(), 'keep');
    },
  );

  test(
    'late cancellation after archive commit retains task-created library files',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'archive-committed-output-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager(initializeSources: () async {});
      final manager = LocalManager();
      await manager.init();
      final task = ArchiveDownloadTask(
        'https://example.invalid/book.zip',
        _archiveComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => _ArchiveDownloader(
          url,
          path,
          Stream.value(const DownloadingStatus(1, 1, 0, true)),
        ),
        extractArchive: (archive, path) async {
          File('$path/cover.jpg').writeAsBytesSync([9]);
        },
      );
      manager.restorePausedDownloads([task]);
      addTearDown(() async {
        task.pause();
        await task.pendingCleanup;
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await task.pendingRun;
      final file = File('${task.path}/cover.jpg');
      expect(manager.find(task.id, task.comicType), isNotNull);
      task.cancel();
      await task.pendingCleanup;
      expect(file.readAsBytesSync(), [9]);
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
    final task = ImagesDownloadTask(
      storage: LocalManager(),
      source: source,
      comicId: 'comic-1',
    );
    LocalManager().restorePausedDownloads([task]);

    task.runRecorder();
    expect(task.timer, isNotNull);

    task.cancel();
    await LocalManager().pendingDownloadTaskWrites;

    expect(task.timer, isNull);
    expect(LocalManager().downloadingTasks, isNot(contains(task)));
  });
}

ComicSource _testSource(
  String key, {
  LoadComicFunc? loadComicInfo,
  LoadComicPagesFunc? loadComicPages,
}) {
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
    loadComicPages,
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
  @override
  Future<void> get pendingCleanup => Future.value();
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

ImagesDownloadTask _pendingImageTask(
  String source,
  String path, {
  List<String>? chapters,
  ComicImageLoader? loadImage,
}) => ImagesDownloadTask.fromJson(LocalManager(), {
  'type': 'ImagesDownloadTask',
  'source': source,
  'comicId': 'pending',
  'comic': {
    'title': 'Pending',
    'subtitle': '',
    'cover': 'cover.jpg',
    'description': '',
    'tags': <String, List<String>>{},
    'chapters': chapters == null ? null : {'kept': 'Kept', 'new/a': 'New'},
    'sourceKey': source,
    'comicId': 'pending',
  },
  'chapters': chapters,
  'path': path,
  'cover': 'cover.jpg',
  'images': {
    chapters == null ? '' : 'new/a': ['image'],
  },
  'downloadedCount': 0,
  'totalCount': 1,
  'index': 0,
  'chapter': 0,
}, loadImage: loadImage)!;

ComicDetails _archiveComic(String source, {String id = 'archive'}) =>
    ComicDetails.fromJson({
      'title': 'Archive',
      'subtitle': '',
      'cover': 'cover.jpg',
      'description': '',
      'tags': <String, List<String>>{},
      'chapters': null,
      'sourceKey': source,
      'comicId': id,
    });

class _ArchiveDownloader extends FileDownloader {
  _ArchiveDownloader(super.url, super.savePath, this.statuses);
  final Stream<DownloadingStatus> statuses;
  @override
  Stream<DownloadingStatus> start() => statuses;
}

class _TaskStorage implements DownloadTaskStorage {
  _TaskStorage(this.path);
  @override
  final String path;
  Future<void> Function()? afterAllocate;
  final completed = <DownloadTask>[];
  final removed = <DownloadTask>[];
  int saves = 0;
  LocalComic? comic;

  @override
  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    final directory = Directory('$path/output')..createSync();
    await afterAllocate?.call();
    return DownloadDirectoryAllocation(directory, isNew: true);
  }

  @override
  LocalComic? find(String id, ComicType type) => comic;

  @override
  Future<void> saveCurrentDownloadingTasks() async => saves++;

  @override
  void completeTask(DownloadTask task) {
    completed.add(task);
    comic = task.toLocalComic();
  }

  @override
  void removeTask(DownloadTask task) => removed.add(task);
}
