import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/local_comics/download_directory_allocator.dart';
import 'package:venera_next/network/images.dart';
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
          comic: archiveDownloadComic(sourceKey, id: 'owned'),
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
            ? pendingImageDownloadTask(
                sourceKey,
                directory.path,
                chapters: ['new/a'],
              )
            : (ImagesDownloadTask(
                storage: LocalManager(),
                source: ComicSource.find(sourceKey)!,
                comicId: 'external',
                comic: archiveDownloadComic(sourceKey, id: 'external'),
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
      final source = downloadFixtureSource(
        sourceKey,
        loadComicPages: (id, ep) async => Res(<String>[]),
      );
      final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);
      final task = ImagesDownloadTask(
        storage: LocalManager(),
        source: source,
        comicId: 'committed',
        comic: archiveDownloadComic(sourceKey, id: 'committed'),
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
          comic: archiveDownloadComic(sourceKey, id: 'thumbnail'),
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
    final source = downloadFixtureSource(
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

  test(
    'late metadata failure from a paused run cannot stop a newer run',
    () async {
      final first = Completer<Res<ComicDetails>>();
      final second = Completer<Res<ComicDetails>>();
      var calls = 0;
      final source = downloadFixtureSource(
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
        downloadFixtureSource(
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
      final task = pendingImageDownloadTask(
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
        final task = pendingImageDownloadTask(
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
      final task = pendingImageDownloadTask(
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
