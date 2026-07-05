import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  test('ImagesDownloadTask cancel before path stops speed recorder', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-download-data-',
    );
    final cacheDir = Directory.systemTemp.createTempSync(
      'venera-download-cache-',
    );
    addTearDown(() async {
      await pumpEventQueue();
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
    await pumpEventQueue();

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
