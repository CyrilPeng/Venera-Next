import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
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

  test(
    'global skip default applies only to new tasks, not restored or overridden tasks',
    () {
      final root = Directory.systemTemp.createTempSync('download-default-');
      final storage = DownloadStorageFixture(root.path);
      addTearDown(() => root.deleteSync(recursive: true));
      appdata.settings['skipUnavailableDownloadImages'] = true;
      final task = ImagesDownloadTask(
        storage: storage,
        source: downloadFixtureSource(sourceKey),
        comicId: 'one',
      );
      final override = ImagesDownloadTask(
        storage: storage,
        source: downloadFixtureSource(sourceKey),
        comicId: 'two',
        skipUnavailableImages: false,
      );
      expect(task.skipUnavailableImages, isTrue);
      expect(override.skipUnavailableImages, isFalse);
      final oldSnapshot = task.toJson()..remove('skipUnavailableImages');
      final restored = ImagesDownloadTask.fromJson(storage, oldSnapshot)!;
      expect(restored.skipUnavailableImages, isFalse);
      appdata.settings['skipUnavailableDownloadImages'] = false;
      expect(task.skipUnavailableImages, isTrue);
      expect(task.isPaused, isTrue);
      task.dispose();
      override.dispose();
      restored.dispose();
    },
  );

  test(
    'incomplete library pages retain positions across restart and repair without redownloading',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'download-partial-library-',
      );
      App.dataPath = root.path;
      App.cachePath = root.path;
      var manager = LocalManager(initializeSources: () async {});
      await manager.init();
      final output = Directory('${manager.path}/partial')..createSync();
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6uwAAAABJRU5ErkJggg==',
      );
      File('${output.path}/cover.png').writeAsBytesSync(bytes);
      var recovered = false;
      final attempts = <String, int>{};
      Stream<ImageDownloadProgress> load(
        String image,
        String? _,
        String _,
        String _,
      ) async* {
        attempts[image] = (attempts[image] ?? 0) + 1;
        if (image == 'missing' && !recovered) {
          final request = RequestOptions(path: image);
          throw DioException.badResponse(
            statusCode: 404,
            requestOptions: request,
            response: Response(requestOptions: request, statusCode: 404),
          );
        }
        yield ImageDownloadProgress(
          currentBytes: bytes.length,
          totalBytes: bytes.length,
          imageBytes: bytes,
        );
      }

      var task = ImagesDownloadTask.fromJson(manager, {
        'type': 'ImagesDownloadTask',
        'source': sourceKey,
        'comicId': 'partial',
        'comic': archiveDownloadComic(sourceKey, id: 'partial').toJson(),
        'chapters': null,
        'path': output.path,
        'cover': 'file://${output.path}/cover.png',
        'images': {
          '': ['first', 'missing', 'last'],
        },
        'downloadedCount': 0,
        'totalCount': 3,
        'index': 0,
        'chapter': 0,
        'skipUnavailableImages': true,
      }, loadImage: load)!;
      try {
        final next = CompletionQueueTask('next');
        manager.restorePausedDownloads([task, next]);
        manager.resumeDownload(task);
        await task.debugResumeFuture;
        await pumpEventQueue();
        expect(task.isAwaitingMissingPages, isTrue);
        expect(next.resumes, 1);
        expect(manager.find(task.id, task.comicType)!.missingImageCount, 1);
        expect(manager.isDownloaded(task.id, task.comicType), isFalse);
        final images = await manager.getImages(task.id, task.comicType, 1);
        expect(images, [
          'file://${p.normalize(p.join(output.path, '0.png'))}',
          'missing-download://2',
          'file://${p.normalize(p.join(output.path, '2.png'))}',
        ]);
        await manager.saveCurrentDownloadingTasks();
        await manager.pendingDownloadTaskWrites;
        manager.dispose();
        task.dispose();
        manager = LocalManager(initializeSources: () async {});
        await manager.init();
        expect(manager.currentDownloadingTask, isNull);
        expect(manager.find('partial', task.comicType)!.isIncomplete, isTrue);
        expect(
          (await manager.getImages('partial', task.comicType, 1))[1],
          'missing-download://2',
        );
        final restored = manager.downloadingTasks.single as ImagesDownloadTask;
        expect(restored.isAwaitingMissingPages, isTrue);
        task = ImagesDownloadTask.fromJson(
          manager,
          restored.toJson(),
          loadImage: load,
        )!;
        restored.dispose();
        manager.restorePausedDownloads([task]);
        recovered = true;
        await manager.retryMissingPages(task);
        await task.debugResumeFuture;
        expect(attempts, {'first': 1, 'missing': 2, 'last': 1});
        expect(manager.downloadingTasks, isEmpty);
        expect(manager.find(task.id, task.comicType)!.isIncomplete, isFalse);
        expect(manager.isDownloaded(task.id, task.comicType), isTrue);
      } finally {
        task.pause();
        await task.pendingCleanup;
        await manager.pendingDownloadTaskWrites;
        task.dispose();
        manager.dispose();
        root.deleteSync(recursive: true);
      }
    },
  );

  for (final skip in [false, true]) {
    for (final restore in [false, true]) {
      test(
        'unavailable images retain an incomplete queue: skip=$skip restore=$restore',
        () async {
          final root = Directory.systemTemp.createTempSync('download-missing-');
          final storage = DownloadStorageFixture(root.path);
          final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6uwAAAABJRU5ErkJggg==',
          );
          var recovered = false;
          final attempts = <String, int>{};
          Stream<ImageDownloadProgress> load(
            String key,
            String? _,
            String _,
            String _,
          ) async* {
            attempts[key] = (attempts[key] ?? 0) + 1;
            if (key == 'missing.png' && !recovered) {
              final request = RequestOptions(path: key);
              throw DioException.badResponse(
                statusCode: 404,
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: 404),
              );
            }
            yield ImageDownloadProgress(
              currentBytes: bytes.length,
              totalBytes: bytes.length,
              imageBytes: bytes,
            );
          }

          var task = ImagesDownloadTask(
            storage: storage,
            source: downloadFixtureSource(
              sourceKey,
              loadComicPages: (_, _) async =>
                  Res(['first.png', 'missing.png', 'last.png']),
            ),
            comicId: 'missing',
            comic: archiveDownloadComic(sourceKey, id: 'missing'),
            skipUnavailableImages: skip,
            loadThumbnail: (_, _) => Stream.value(
              ImageDownloadProgress(
                currentBytes: bytes.length,
                totalBytes: bytes.length,
                imageBytes: bytes,
              ),
            ),
            loadImage: load,
          );
          try {
            task.resume();
            await task.debugResumeFuture;
            expect(task.isError, !skip);
            expect(task.isAwaitingMissingPages, skip);
            expect(storage.comic?.isIncomplete, skip ? isTrue : isNull);
            expect(storage.completed, isEmpty);
            expect(attempts['last.png'], skip ? 1 : null);
            expect(task.missingImageCount, skip ? 1 : 0);
            expect(
              task.progress,
              skip ? closeTo(2 / 3, 0.001) : closeTo(1 / 3, 0.001),
            );
            if (skip) {
              expect(task.message, contains('Waiting for missing pages'));
            }
            if (restore) {
              await task.pendingCleanup;
              final snapshot =
                  jsonDecode(jsonEncode(task.toJson())) as Map<String, dynamic>;
              task.dispose();
              task = ImagesDownloadTask.fromJson(
                storage,
                snapshot,
                loadImage: load,
              )!;
              expect(task.skipUnavailableImages, skip);
              expect(task.missingImageCount, skip ? 1 : 0);
            }
            recovered = true;
            task.resume();
            await task.debugResumeFuture;
            expect(storage.completed, [same(task)]);
            expect(task.progress, 1);
            expect(task.missingImageCount, 0);
            expect(attempts, {'first.png': 1, 'missing.png': 2, 'last.png': 1});
            for (final index in [0, 1, 2]) {
              expect(File('${task.path}/$index.png').readAsBytesSync(), bytes);
            }
          } finally {
            task.pause();
            await task.pendingCleanup;
            task.dispose();
            root.deleteSync(recursive: true);
          }
        },
      );
    }
  }

  for (final recovery in ['network', 'resume', 'exhausted']) {
    test(
      'transient image disconnect preserves completed pages: $recovery',
      () async {
        final root = Directory.systemTemp.createTempSync('download-recovery-');
        final storage = DownloadStorageFixture(root.path);
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6uwAAAABJRU5ErkJggg==',
        );
        var connected = false;
        final attempts = <String, int>{};
        final task = ImagesDownloadTask(
          storage: storage,
          source: downloadFixtureSource(
            sourceKey,
            loadComicPages: (_, _) async => Res(['first.png', 'second.png']),
          ),
          comicId: 'recovery',
          comic: archiveDownloadComic(sourceKey, id: 'recovery'),
          loadThumbnail: (_, _) => Stream.value(
            ImageDownloadProgress(
              currentBytes: bytes.length,
              totalBytes: bytes.length,
              imageBytes: bytes,
            ),
          ),
          loadImage: (key, _, _, _) async* {
            attempts[key] = (attempts[key] ?? 0) + 1;
            if (key == 'second.png' && !connected) {
              throw DioException(
                requestOptions: RequestOptions(
                  path: 'https://example.invalid/second.png',
                ),
                error: rhttp.RhttpConnectionException(
                  rhttp.HttpRequest(url: 'https://example.invalid/second.png'),
                  'offline',
                ),
              );
            }
            yield ImageDownloadProgress(
              currentBytes: bytes.length,
              totalBytes: bytes.length,
              imageBytes: bytes,
            );
          },
        );
        addTearDown(() async {
          task.pause();
          await task.pendingCleanup;
          await task.debugResumeFuture;
          task.dispose();
          root.deleteSync(recursive: true);
        });
        task.resume();
        await waitForDownloadTask(() => task.isWaitingToRetry);
        expect(task.isPaused, isFalse);
        expect(task.isError, isFalse);
        expect(task.message, contains('Waiting to retry'));
        expect(task.progress, 0.5);
        expect(task.toJson()['index'], 1);
        expect(File('${task.path}/0.png').readAsBytesSync(), bytes);
        if (recovery == 'resume') {
          task.pause();
          await task.pendingCleanup;
          await task.debugResumeFuture;
          task.retryNow();
          await pumpEventQueue();
          expect(attempts['second.png'], 1);
          expect(task.isWaitingToRetry, isFalse);
          connected = true;
          task.resume();
        } else if (recovery == 'exhausted') {
          for (var attempt = 2; attempt <= 7; attempt++) {
            task.retryNow();
            await waitForDownloadTask(() => attempts['second.png'] == attempt);
            await pumpEventQueue();
          }
          await task.debugResumeFuture;
          expect(task.isPaused, isTrue);
          expect(task.isError, isTrue);
          expect(task.isWaitingToRetry, isFalse);
          connected = true;
          task.retryNow();
          await pumpEventQueue();
          expect(attempts['second.png'], 7);
          expect(storage.completed, isEmpty);
          task.resume();
        } else {
          connected = true;
          task.retryNow();
        }
        await task.debugResumeFuture;
        expect(task.progress, 1);
        expect(task.isError, isFalse);
        expect(attempts['first.png'], 1);
        expect(attempts['second.png'], recovery == 'exhausted' ? 8 : 2);
        expect(storage.completed, [same(task)]);
        expect(File('${task.path}/0.png').readAsBytesSync(), bytes);
      },
    );
  }

  test(
    'image retry releases the old stream before waiting or opening a new one',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'download-retry-cleanup-',
      );
      final storage = DownloadStorageFixture(root.path);
      final cancelling = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      final task = ImagesDownloadTask(
        storage: storage,
        source: downloadFixtureSource(
          sourceKey,
          loadComicPages: (_, _) async => Res(['page.png']),
        ),
        comicId: 'cleanup',
        comic: archiveDownloadComic(sourceKey, id: 'cleanup'),
        loadThumbnail: (_, _) => Stream.value(
          ImageDownloadProgress(
            currentBytes: 3,
            totalBytes: 3,
            imageBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
        loadImage: (_, _, _, _) {
          calls++;
          final controller = StreamController<ImageDownloadProgress>();
          controller.onListen = () =>
              controller.addError(const SocketException('offline'));
          controller.onCancel = () async {
            if (!cancelling.isCompleted) cancelling.complete();
            await release.future;
          };
          return controller.stream;
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        task.pause();
        await task.pendingCleanup;
        await task.debugResumeFuture;
        task.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await cancelling.future;
      task.retryNow();
      await pumpEventQueue();
      expect(calls, 1);
      expect(task.isWaitingToRetry, isFalse);
      release.complete();
      await waitForDownloadTask(() => task.isWaitingToRetry);
      task.cancel();
      await task.pendingCleanup;
      await task.debugResumeFuture;
      task.retryNow();
      await pumpEventQueue();
      expect(calls, 1);
      expect(storage.removed, [same(task)]);
    },
  );

  test(
    'image download retains its injected library across allocation',
    () async {
      final root = Directory.systemTemp.createTempSync('download-owner-');
      final storage = DownloadStorageFixture(root.path);
      final allocated = Completer<void>();
      final release = Completer<void>();
      storage.afterAllocate = () async {
        allocated.complete();
        await release.future;
      };
      final task = ImagesDownloadTask(
        storage: storage,
        source: downloadFixtureSource(
          sourceKey,
          loadComicPages: (_, _) async => Res([]),
        ),
        comicId: 'owned',
        comic: archiveDownloadComic(sourceKey, id: 'owned'),
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

  for (final kind in [FailureKind.cancelled, FailureKind.unsupported]) {
    test('download does not retry a structured $kind source result', () async {
      final root = Directory.systemTemp.createTempSync('download-failure-');
      var calls = 0;
      final task = ImagesDownloadTask(
        storage: DownloadStorageFixture(root.path),
        source: downloadFixtureSource(
          sourceKey,
          loadComicInfo: (_) async {
            calls++;
            return Res.failure(
              OperationFailure.message('source stopped', kind: kind),
            );
          },
        ),
        comicId: 'stopped',
      );
      addTearDown(() async {
        task.pause();
        await task.pendingCleanup;
        root.deleteSync(recursive: true);
      });
      task.resume();
      await task.debugResumeFuture;
      expect(calls, 1);
      expect(task.isError, isTrue);
      expect(task.message, contains('source stopped'));
    });
  }

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
}
