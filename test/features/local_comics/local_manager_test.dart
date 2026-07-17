import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';

const _testComicType = ComicType(9001);

LocalComic _localComic(String id) {
  return LocalComic(
    id: id,
    title: 'Local $id',
    subtitle: 'Author',
    tags: const ['tag'],
    directory: id,
    chapters: null,
    cover: 'cover.jpg',
    comicType: _testComicType,
    downloadedChapters: const [],
    createdAt: DateTime(2026, 1, 1),
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test(
    'getImages filters non-images and sorts numeric page names',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-local-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-local-cache-',
      );
      addTearDown(() {
        LocalManager.resetForTesting();
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();

      final comic = _localComic('pages');
      final directory = Directory(
        '${manager.path}${Platform.pathSeparator}pages',
      )..createSync(recursive: true);
      File(
        '${directory.path}${Platform.pathSeparator}cover.jpg',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}10.JPG',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}2.jpg',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}metadata.json',
      ).writeAsStringSync('{}');
      File(
        '${directory.path}${Platform.pathSeparator}.hidden.png',
      ).writeAsBytesSync([1]);
      await manager.add(comic);

      final images = await manager.getImages(comic.id, comic.comicType, 1);

      expect(images.map((image) => image.split(RegExp(r'[/\\]')).last), [
        '2.jpg',
        '10.JPG',
      ]);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'single local comic deletes notify once',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-local-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-local-cache-',
      );
      addTearDown(() {
        LocalManager.resetForTesting();
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;

      final manager = LocalManager();
      await manager.init();

      var notifyCount = 0;
      var isDeleting = false;
      void listener() {
        if (isDeleting) {
          notifyCount++;
        }
      }

      manager.addListener(listener);

      final first = _localComic('first');
      await manager.add(first);
      isDeleting = true;
      manager.removeComic(first);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(first.id, first.comicType), isNull);

      final second = _localComic('second');
      await manager.add(second);
      notifyCount = 0;
      isDeleting = true;
      manager.deleteComic(second, false);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(second.id, second.comicType), isNull);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
