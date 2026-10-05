import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late LocalManager local;
  late LocalFavoritesManager favorites;
  late HistoryManager history;
  late Database faultDb;
  late LocalComic comic;
  late File page;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('local-delete-failure-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    LocalFavoritesManager.cache = null;
    HistoryManager.cache = null;
    local = LocalManager();
    favorites = LocalFavoritesManager();
    history = HistoryManager();
    await local.init();
    await favorites.init();
    await history.init();
    comic = LocalComic(
      id: 'book',
      title: 'Book',
      subtitle: '',
      tags: [],
      directory: 'book',
      chapters: null,
      cover: '',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2026),
    );
    await local.add(comic);
    await history.addHistory(
      History.fromMap({
        'type': comic.comicType.value,
        'time': 1,
        'title': 'Book',
        'subtitle': '',
        'cover': '',
        'ep': 1,
        'page': 2,
        'id': comic.id,
        'readEpisode': ['1'],
        'max_page': 10,
      }),
    );
    final directory = Directory('${local.path}/book')..createSync();
    page = File('${directory.path}/1.jpg')..writeAsStringSync('keep');
    for (final folder in ['first', 'second']) {
      await favorites.createFolder(folder);
      await favorites.addComic(
        folder,
        FavoriteItem(
          id: comic.id,
          name: comic.title,
          coverPath: '',
          author: '',
          type: comic.comicType,
          tags: [],
        ),
      );
    }
    faultDb = sqlite3.open('${root.path}/local_favorite.db');
    faultDb.execute(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON second BEGIN SELECT RAISE(ABORT, 'injected'); END;",
    );
    await favorites.debugWaitForHashedIdsRefresh();
  });

  tearDown(() async {
    faultDb.dispose();
    await history.waitForAsyncWrites();
    history.close();
    HistoryManager.cache = null;
    await favorites.debugWaitForHashedIdsRefresh();
    await favorites.closeAndWait();
    LocalFavoritesManager.cache = null;
    await local.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    await appdata.saveData(false);
    root.deleteSync(recursive: true);
  });

  test(
    'single deletion rolls back all favorite folders and permits retry',
    () async {
      var notifications = 0;
      favorites.addListener(() => notifications++);
      await expectLater(
        local.deleteComic(comic),
        throwsA(isA<SqliteException>()),
      );
      expect(favorites.folderComics('first'), 1);
      expect(favorites.folderComics('second'), 1);
      expect(notifications, 0);
      expect(history.find(comic.id, comic.comicType), isNotNull);
      expect(local.find(comic.id, comic.comicType), isNotNull);
      expect(page.readAsStringSync(), 'keep');
      faultDb.execute('DROP TRIGGER reject_delete;');
      await local.deleteComic(comic);
      expect(favorites.folderComics('first'), 0);
      expect(favorites.folderComics('second'), 0);
      expect(notifications, 1);
      expect(local.find(comic.id, comic.comicType), isNull);
      expect(page.existsSync(), isFalse);
    },
  );

  test(
    'batch deletion propagates favorite failure before file cleanup',
    () async {
      await expectLater(
        local.batchDeleteComics([comic]),
        throwsA(isA<SqliteException>()),
      );
      expect(favorites.folderComics('first'), 1);
      expect(favorites.folderComics('second'), 1);
      expect(page.readAsStringSync(), 'keep');
      // The separate local/history/filesystem transaction remains a follow-up;
      // this assertion covers failure propagation and preserving file contents.
    },
  );

  for (final failingDatabase in ['local', 'history']) {
    test('$failingDatabase failure rolls back all three databases', () async {
      faultDb.execute('DROP TRIGGER reject_delete;');
      final db = sqlite3.open('${root.path}/$failingDatabase.db');
      final table = failingDatabase == 'local' ? 'comics' : 'history';
      try {
        db.execute(
          "CREATE TRIGGER reject_delete BEFORE DELETE ON $table BEGIN SELECT RAISE(ABORT, 'injected'); END;",
        );
        await expectLater(
          local.batchDeleteComics([comic]),
          throwsA(isA<SqliteException>()),
        );
        expect(local.find(comic.id, comic.comicType), isNotNull);
        expect(history.find(comic.id, comic.comicType), isNotNull);
        expect(favorites.folderComics('first'), 1);
        expect(favorites.folderComics('second'), 1);
        expect(page.readAsStringSync(), 'keep');
        db.execute('DROP TRIGGER reject_delete;');
        await local.batchDeleteComics([comic]);
        expect(local.count, 0);
        expect(history.find(comic.id, comic.comicType), isNull);
        expect(favorites.folderComics('first'), 0);
        expect(favorites.folderComics('second'), 0);
        expect(page.existsSync(), isFalse);
      } finally {
        db.dispose();
      }
    });
  }

  test(
    'queued progress completes before deletion and caches publish committed state',
    () async {
      faultDb.execute('DROP TRIGGER reject_delete;');
      final item = history.find(comic.id, comic.comicType)!.copy()..page = 5;
      final writing = history.addHistory(item);
      var publications = 0;
      favorites.addListener(() {
        publications++;
        expect(local.find(comic.id, comic.comicType), isNull);
        expect(history.find(comic.id, comic.comicType), isNull);
        expect(favorites.folderComics('first'), 0);
        expect(favorites.folderComics('second'), 0);
      });
      await local.batchDeleteComics([comic]);
      await writing;
      await history.waitForAsyncWrites();
      expect(publications, 1);
      expect(history.find(comic.id, comic.comicType), isNull);
    },
  );

  test(
    'attached favorite tables cannot collide with local tables or identifiers',
    () async {
      faultDb.execute('DROP TRIGGER reject_delete;');
      for (final folder in ['comics', 'quoted"folder']) {
        await favorites.createFolder(folder);
        await favorites.addComic(
          folder,
          FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: '',
            author: '',
            type: comic.comicType,
            tags: [],
          ),
        );
      }
      await local.batchDeleteComics([comic]);
      expect(local.count, 0);
      expect(favorites.folderComics('comics'), 0);
      expect(favorites.folderComics('quoted"folder'), 0);
      expect(history.find(comic.id, comic.comicType), isNull);
    },
  );
}
