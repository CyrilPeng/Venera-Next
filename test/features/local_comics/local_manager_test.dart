import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';

const _testComicType = ComicType(9001);

LocalComic _localComic(String id, {List<String> downloaded = const []}) {
  return LocalComic(
    id: id,
    title: 'Local $id',
    subtitle: 'Author',
    tags: const ['tag'],
    directory: id,
    chapters: null,
    cover: 'cover.jpg',
    comicType: _testComicType,
    downloadedChapters: downloaded,
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
  test('record writes require the active exclusive owner', () async {
    final root = Directory.systemTemp.createTempSync('local-writer-owner-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    final manager = LocalManager();
    await manager.init();
    final first = _localComic('first');
    await manager.add(first);
    final gate = Completer<void>();
    final entered = Completer<void>();
    final exclusive = manager.runWithExclusiveStorage(() async {
      await manager.add(_localComic('owned'));
      entered.complete();
      await gate.future;
    });
    try {
      await entered.future;
      await expectLater(
        manager.add(_localComic('unrelated')),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(
        () => manager.remove(first.id, first.comicType),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(manager.find(first.id, first.comicType), isNotNull);
      expect(manager.find('owned', first.comicType), isNotNull);
      expect(manager.find('unrelated', first.comicType), isNull);
      gate.complete();
      await exclusive;
      manager.remove(first.id, first.comicType);
      expect(manager.find(first.id, first.comicType), isNull);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await exclusive;
      await manager.pendingDownloadTaskWrites;
      LocalManager.resetForTesting();
      root.deleteSync(recursive: true);
    }
  });

  test(
    'deletion rejects importing and uses current registered output before completing',
    () async {
      final root = Directory.systemTemp.createTempSync('local-delete-owner-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      final stale = _localComic('old', downloaded: ['a']);
      await manager.add(stale);
      final oldDirectory = Directory('${manager.path}/old')..createSync();
      File('${oldDirectory.path}/keep.jpg').writeAsStringSync('keep');
      final currentDirectory = Directory('${manager.path}/current')
        ..createSync();
      File('${currentDirectory.path}/page.jpg').writeAsStringSync('current');
      db.execute("UPDATE comics SET directory = 'current' WHERE id = 'old'");
      final gate = Completer<void>();
      final importing = LocalComicStorageGuard.instance.runImport(
        () => gate.future,
      );
      try {
        await expectLater(
          manager.deleteComic(stale),
          throwsA(isA<LocalComicStorageBusy>()),
        );
        await expectLater(
          manager.deleteComicChapters(stale, ['a']),
          throwsA(isA<LocalComicStorageBusy>()),
        );
        await expectLater(
          manager.batchDeleteComics([stale], true, false),
          throwsA(isA<LocalComicStorageBusy>()),
        );
        expect(manager.find(stale.id, stale.comicType), isNotNull);
        expect(currentDirectory.existsSync(), isTrue);
        gate.complete();
        await importing;
        await manager.deleteComic(stale);
        expect(currentDirectory.existsSync(), isFalse);
        expect(
          File('${oldDirectory.path}/keep.jpg').readAsStringSync(),
          'keep',
        );
        expect(manager.find(stale.id, stale.comicType), isNull);
        await manager.runWithExclusiveStorage(() async {});
      } finally {
        if (!gate.isCompleted) gate.complete();
        await importing;
        db.dispose();
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'deletions notify after storage succeeds and retain files on failure',
    () async {
      final root = Directory.systemTemp.createTempSync('local-delete-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      final db = sqlite3.open('${root.path}/local.db');
      addTearDown(() {
        db.dispose();
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      });
      final first = _localComic('first', downloaded: const ['a', 'b']);
      final second = _localComic('second');
      await manager.add(first);
      await manager.add(second);
      final chapter = Directory('${manager.path}/first/a')
        ..createSync(recursive: true);
      final file = File('${chapter.path}/page.jpg')..writeAsBytesSync([1]);
      var notifications = 0;
      manager.addListener(() => notifications++);
      db.execute(
        "CREATE TRIGGER reject_update BEFORE UPDATE ON comics BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      await expectLater(
        manager.deleteComicChapters(first, ['a']),
        throwsA(isA<SqliteException>()),
      );
      expect(file.existsSync(), isTrue);
      expect(notifications, 0);
      db.execute('DROP TRIGGER reject_update;');
      db.execute(
        "CREATE TRIGGER reject_second BEFORE DELETE ON comics WHEN OLD.id = 'second' BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      await expectLater(
        manager.batchDeleteComics([first, second], true, false),
        throwsA(isA<SqliteException>()),
      );
      expect(manager.count, 2);
      expect(file.existsSync(), isTrue);
      expect(notifications, 0);
      db.execute('DROP TRIGGER reject_second;');
      await manager.batchDeleteComics([first, second], false, false);
      expect(manager.count, 0);
      expect(db.select('SELECT * FROM natural_sort_migration'), isEmpty);
      expect(file.existsSync(), isTrue);
      expect(notifications, 1);
    },
  );

  test(
    'chapter deletion uses latest download state before notifying',
    () async {
      final root = Directory.systemTemp.createTempSync('local-chapter-delete-');
      App.dataPath = root.path;
      App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();
      addTearDown(() {
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      });
      final stale = _localComic('1', downloaded: const ['a']);
      await manager.add(stale);
      await manager.add(_localComic('1', downloaded: const ['new']));
      var notifications = 0;
      manager.addListener(() {
        notifications++;
        expect(manager.find('1', stale.comicType)!.downloadedChapters, ['new']);
      });
      await manager.deleteComicChapters(stale, ['a']);
      expect(notifications, 1);
      expect(stale.downloadedChapters, ['a']);
    },
  );

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
        '${directory.path}${Platform.pathSeparator}3.avif',
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
        '3.avif',
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
      manager.remove(first.id, first.comicType);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(first.id, first.comicType), isNull);

      final second = _localComic('second');
      await manager.add(second);
      notifyCount = 0;
      isDeleting = true;
      await manager.deleteComic(second, false);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(second.id, second.comicType), isNull);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
