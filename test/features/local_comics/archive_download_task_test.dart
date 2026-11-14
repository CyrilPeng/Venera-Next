import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/network/file_downloader.dart';
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
    'archive retry keeps its workspace and drains the failed downloader',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-recovery-');
      App.cachePath = root.path;
      final storage = DownloadStorageFixture(root.path);
      final downloads = <ControlledArchiveDownloader>[];
      String? firstPath;
      final task = ArchiveDownloadTask(
        'https://example.invalid/book.zip',
        archiveDownloadComic(sourceKey),
        storage: storage,
        createDownloader: (url, path) {
          if (firstPath == null) {
            firstPath = path;
            File('$path.download').writeAsStringSync('partial');
          } else {
            expect(path, firstPath);
            expect(File('$path.download').readAsStringSync(), 'partial');
            expect(downloads.first.stopped, isTrue);
          }
          final downloader = ControlledArchiveDownloader(
            url,
            path,
            downloads.isEmpty
                ? Stream.error(const SocketException('offline'))
                : Stream.value(DownloadingStatus(10, 10, 0, true)),
          );
          downloads.add(downloader);
          return downloader;
        },
        extractArchive: (_, output) async =>
            File('$output/0.jpg').writeAsBytesSync([1, 2, 3]),
      );
      addTearDown(() async {
        task.pause();
        await task.pendingCleanup;
        task.dispose();
        root.deleteSync(recursive: true);
      });
      task.resume();
      await waitForDownloadTask(() => task.isWaitingToRetry);
      expect(task.isPaused, isFalse);
      task.retryNow();
      await task.pendingRun;
      expect(downloads, hasLength(2));
      expect(task.isError, isFalse);
      expect(storage.completed, [same(task)]);
      expect(File('$firstPath.download').existsSync(), isFalse);
    },
  );

  test(
    'archive download retains its library while extraction drains',
    () async {
      final root = Directory.systemTemp.createTempSync('archive-owner-');
      App.cachePath = root.path;
      final storage = DownloadStorageFixture(root.path);
      final extracting = Completer<void>();
      final release = Completer<void>();
      final task = ArchiveDownloadTask(
        'https://example.invalid/owned.zip',
        archiveDownloadComic(sourceKey),
        storage: storage,
        createDownloader: (url, path) => ControlledArchiveDownloader(
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
        archiveDownloadComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) {
          transfers++;
          transferPaths.add(path);
          File(path).writeAsStringSync('zip');
          return ControlledArchiveDownloader(
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
        archiveDownloadComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => ControlledArchiveDownloader(
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
      final next = CompletionQueueTask('after-archive');
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
        archiveDownloadComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => ControlledArchiveDownloader(
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
          archiveDownloadComic(sourceKey, id: 'archive-$index'),
          storage: LocalManager(),
          createDownloader: (url, path) {
            paths['$index'] = path;
            File(path).writeAsStringSync('zip-$index');
            File('$path.download').writeAsStringSync('resume-$index');
            return ControlledArchiveDownloader(
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
        archiveDownloadComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => ControlledArchiveDownloader(
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
        archiveDownloadComic(sourceKey, id: 'external'),
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
        archiveDownloadComic(sourceKey),
        storage: LocalManager(),
        createDownloader: (url, path) => ControlledArchiveDownloader(
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
}
