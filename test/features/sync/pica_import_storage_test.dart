import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/features/history/image_favorites_repository.dart';
import 'package:venera_next/features/sync/legacy_pica_data.dart';
import 'package:venera_next/features/sync/pica_import_storage.dart';

void main() {
  late Directory root;
  late Database favoritesDb;
  late Database historyDb;
  late LegacyPicaData data;
  late FavoritesRepository favorites;
  late HistoryRepository history;
  late ImageFavoritesRepository images;
  final linkErrors = <Object>[];
  setUp(() {
    root = Directory.systemTemp.createTempSync('pica-storage-');
    final source = Directory('${root.path}/source')..createSync();
    final oldFavorites = sqlite3.open('${source.path}/local_favorite.db');
    try {
      oldFavorites.execute(
        'CREATE TABLE folder_sync (folder_name TEXT, key TEXT, sync_data TEXT);',
      );
      oldFavorites.execute(
        "INSERT INTO folder_sync VALUES ('imported', 'source', '{\"folderId\":\"remote\"}');",
      );
      oldFavorites.execute(
        'CREATE TABLE imported (target TEXT, type INT, name TEXT, author TEXT, cover_path TEXT, tags TEXT);',
      );
      oldFavorites.execute(
        "INSERT INTO imported VALUES ('book', 0, 'Title', 'Author', 'Cover', 'tag');",
      );
    } finally {
      oldFavorites.dispose();
    }
    final oldHistory = sqlite3.open('${source.path}/history.db');
    try {
      oldHistory.execute(
        'CREATE TABLE history (target TEXT, type INT, max_page INT, ep INT, page INT, time INT, title TEXT, subtitle TEXT, cover TEXT);',
      );
      oldHistory.execute(
        "INSERT INTO history VALUES ('book', 0, 20, 2, 7, 1234, 'Title', '', '');",
      );
      oldHistory.execute(
        'CREATE TABLE image_favorites (id TEXT, ep INT, page INT, title TEXT);',
      );
      oldHistory.execute(
        "INSERT INTO image_favorites VALUES ('source-book-part', 1, 2, 'Image title'), ('source-book-part', 1, 3, 'Image title'), ('source-book-part', 2, 4, 'Image title');",
      );
    } finally {
      oldHistory.dispose();
    }
    data = LegacyPicaData.read(source.path, sourceAvailable: (_) => true);
    favoritesDb = sqlite3.open('${root.path}/favorites.db');
    historyDb = sqlite3.open('${root.path}/history-target.db');
    favorites = FavoritesRepository(favoritesDb)..initializeMetadata();
    history = HistoryRepository(historyDb)..initialize();
    images = ImageFavoritesRepository(historyDb)..initialize();
    linkErrors.clear();
  });
  tearDown(() {
    favoritesDb.dispose();
    historyDb.dispose();
    root.deleteSync(recursive: true);
  });
  void commit() => commitLegacyPicaData(
    data,
    favoritesPath: '${root.path}/favorites.db',
    historyPath: '${root.path}/history-target.db',
    appendFavorites: true,
    translateTags: (tags) => 'translated',
    invalidLink: (error, stack) => linkErrors.add(error),
  );

  test(
    'WAL targets are rejected before writes without changing journal mode',
    () {
      historyDb.execute('PRAGMA journal_mode = WAL;');
      expect(commit, throwsStateError);
      expect(favorites.folderNames(), isEmpty);
      expect(history.count(), 0);
      expect(
        historyDb.select('PRAGMA journal_mode;').first['journal_mode'],
        'wal',
      );
      historyDb.execute('PRAGMA journal_mode = DELETE;');
      commit();
      expect(history.count(), 1);
    },
  );

  test(
    'late image failure rolls back folders, links, history and allows retry',
    () {
      historyDb.execute(
        "CREATE TRIGGER reject_image BEFORE INSERT ON image_favorites BEGIN SELECT RAISE(ABORT, 'injected'); END;",
      );
      expect(commit, throwsA(isA<SqliteException>()));
      expect(favorites.folderNames(), isEmpty);
      expect(favorites.findLinked('imported'), (null, null));
      expect(history.count(), 0);
      expect(images.count(), 0);
      historyDb.execute('DROP TRIGGER reject_image;');
      commit();
      expect(favorites.getFolderComics('imported').single.id, 'book');
      expect(favorites.findLinked('imported'), ('source', 'remote'));
      expect(history.getAll().single.page, 7);
      expect(
        images
            .find('book-part', 'source')!
            .images
            .map((image) => (image.ep, image.page)),
        [(1, 2), (1, 3), (2, 4)],
      );
      commit();
      expect(favorites.count('imported'), 1);
      expect(history.count(), 1);
      expect(images.find('book-part', 'source')!.images, hasLength(3));
    },
  );

  test(
    'merge keeps existing metadata and image keys without rewriting unrelated rows',
    () {
      images.save(
        ImageFavoritesComic(
          'book-part',
          [
            ImageFavoritesEp(
              'eid',
              1,
              [
                ImageFavorite(
                  2,
                  'existing-key',
                  true,
                  'eid',
                  'book-part',
                  1,
                  'source',
                  'Existing chapter',
                ),
              ],
              'Existing chapter',
              30,
            ),
          ],
          'Existing title',
          'source',
          [],
          [],
          DateTime(2026),
          '',
          {},
          '',
          30,
        ),
      );
      // Corrupt unrelated data must not be loaded and rewritten by this import.
      historyDb.execute(
        "INSERT INTO image_favorites (id, title, source_key, image_favorites_ep, other) VALUES ('untouched', 'Untouched', 'other', 'invalid-json', '{}');",
      );
      historyDb.execute(
        "CREATE TRIGGER reject_unrelated BEFORE INSERT ON image_favorites WHEN new.id = 'untouched' BEGIN SELECT RAISE(ABORT, 'unexpected rewrite'); END;",
      );
      commit();
      final merged = images.find('book-part', 'source')!;
      expect(merged.title, 'Existing title');
      expect(merged.imageFavoritesEp.first.eid, 'eid');
      expect(merged.imageFavoritesEp.first.maxPage, 30);
      expect(merged.images.first.imageKey, 'existing-key');
      expect(merged.images.first.isAutoFavorite, isTrue);
      expect(merged.images.map((image) => (image.ep, image.page)), [
        (1, 2),
        (1, 3),
        (2, 4),
      ]);
      expect(images.count(), 2);
    },
  );

  test(
    'invalid optional link is skipped but link SQL failures abort the import',
    () {
      final source = sqlite3.open('${root.path}/source/local_favorite.db');
      try {
        source.execute("UPDATE folder_sync SET sync_data = 'invalid';");
      } finally {
        source.dispose();
      }
      data = LegacyPicaData.read(
        '${root.path}/source',
        sourceAvailable: (_) => true,
      );
      commit();
      expect(linkErrors, hasLength(1));
      expect(favorites.count('imported'), 1);
      expect(favorites.findLinked('imported'), (null, null));
      favoritesDb.execute(
        "CREATE TRIGGER reject_link BEFORE INSERT ON folder_sync BEGIN SELECT RAISE(ABORT, 'injected link'); END;",
      );
      final repair = sqlite3.open('${root.path}/source/local_favorite.db');
      try {
        repair.execute(
          "UPDATE folder_sync SET sync_data = '{\"folderId\":\"remote\"}';",
        );
      } finally {
        repair.dispose();
      }
      data = LegacyPicaData.read(
        '${root.path}/source',
        sourceAvailable: (_) => true,
      );
      expect(commit, throwsA(isA<SqliteException>()));
      expect(favorites.findLinked('imported'), (null, null));
    },
  );
}
