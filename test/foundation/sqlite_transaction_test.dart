import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorites_repository.dart';

void main() {
  late Database db;
  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('CREATE TABLE records (value TEXT);');
  });
  tearDown(() => db.dispose());
  List<String> values() => db
      .select('SELECT value FROM records ORDER BY rowid;')
      .map((row) => row[0] as String)
      .toList();

  test('inner success does not commit the enclosing transaction', () {
    db.execute('BEGIN IMMEDIATE;');
    final result = runSqliteTransaction(db, () {
      db.execute("INSERT INTO records VALUES ('inner');");
      return 42;
    }, immediate: true);
    expect(result, 42);
    expect(db.autocommit, isFalse);
    db.execute('ROLLBACK;');
    expect(values(), isEmpty);
    final error = StateError('outer failure');
    expect(
      () => runSqliteTransaction(db, () {
        runSqliteTransaction(
          db,
          () => db.execute("INSERT INTO records VALUES ('nested');"),
        );
        throw error;
      }),
      throwsA(same(error)),
    );
    expect(values(), isEmpty);
    expect(db.autocommit, isTrue);
  });

  test(
    'caught inner failure restores its savepoint and outer work can commit',
    () {
      final error = StateError('inner failure');
      runSqliteTransaction(db, () {
        db.execute("INSERT INTO records VALUES ('before');");
        expect(
          () => runSqliteTransaction(db, () {
            db.execute("INSERT INTO records VALUES ('discard');");
            throw error;
          }),
          throwsA(same(error)),
        );
        runSqliteTransaction(
          db,
          () => db.execute("INSERT INTO records VALUES ('after');"),
        );
      });
      expect(values(), ['before', 'after']);
      expect(db.autocommit, isTrue);
    },
  );

  test(
    'commit failure rolls back and SQLite automatic rollback keeps its error',
    () {
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('CREATE TABLE parent (id INTEGER PRIMARY KEY);');
      db.execute(
        'CREATE TABLE child (id INT REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);',
      );
      expect(
        () => runSqliteTransaction(db, () {
          db.execute('INSERT INTO child VALUES (10);');
          db.execute("INSERT INTO records VALUES ('discard');");
        }),
        throwsA(isA<SqliteException>()),
      );
      expect(db.select('SELECT * FROM child;'), isEmpty);
      expect(values(), isEmpty);
      expect(db.autocommit, isTrue);
      db.execute(
        "CREATE TRIGGER abort_transaction BEFORE INSERT ON records BEGIN SELECT RAISE(ROLLBACK, 'original failure'); END;",
      );
      expect(
        () => runSqliteTransaction(db, () {
          runSqliteTransaction(
            db,
            () => db.execute("INSERT INTO records VALUES ('fail');"),
          );
        }),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.message,
            'message',
            contains('original failure'),
          ),
        ),
      );
      expect(db.autocommit, isTrue);
      db.execute('DROP TRIGGER abort_transaction;');
      runSqliteTransaction(
        db,
        () => db.execute("INSERT INTO records VALUES ('retry');"),
      );
      expect(values(), ['retry']);
    },
  );

  test('deferred and immediate root modes preserve writer lock policy', () {
    final root = Directory.systemTemp.createTempSync('sqlite-scope-');
    final first = sqlite3.open('${root.path}/test.db');
    final second = sqlite3.open('${root.path}/test.db');
    try {
      first.execute('CREATE TABLE records (value TEXT);');
      second.execute('PRAGMA busy_timeout = 0;');
      runSqliteTransaction(first, () {
        second.execute("INSERT INTO records VALUES ('deferred');");
      });
      runSqliteTransaction(first, () {
        expect(
          () => second.execute("INSERT INTO records VALUES ('blocked');"),
          throwsA(isA<SqliteException>()),
        );
      }, immediate: true);
      second.execute("INSERT INTO records VALUES ('released');");
      expect(first.select('SELECT value FROM records;').map((row) => row[0]), [
        'deferred',
        'released',
      ]);
    } finally {
      first.dispose();
      second.dispose();
      root.deleteSync(recursive: true);
    }
  });

  test(
    'favorites, history and image repositories join one caller transaction',
    () {
      final favorites = FavoritesRepository(db);
      final history = HistoryRepository(db);
      final images = ImageFavoritesRepository(db);
      favorites.initializeMetadata();
      favorites.createFolder('favorites');
      history.initialize();
      images.initialize();
      final favorite = FavoriteItem(
        id: 'book',
        name: 'Title',
        coverPath: '',
        author: '',
        type: ComicType(1),
        tags: [],
      );
      final progress = History(
        type: ComicType(1),
        id: 'book',
        maxPage: 10,
        ep: 1,
        page: 2,
        time: DateTime(2026),
        title: 'Title',
        subtitle: '',
        cover: '',
        readEpisode: {'1'},
        readDurationMs: 0,
      );
      final image = ImageFavoritesComic(
        'book',
        [
          ImageFavoritesEp(
            'chapter',
            1,
            [ImageFavorite(2, 'key', null, 'chapter', 'book', 1, 'source', '')],
            '',
            10,
          ),
        ],
        'Title',
        'source',
        [],
        [],
        DateTime(2026),
        '',
        {},
        '',
        10,
      );
      void writeAll() {
        favorites.addComic(
          'favorites',
          favorite,
          translatedTags: '',
          append: true,
        );
        history.importHistory(progress);
        images.saveAll([image]);
      }

      db.execute(
        "CREATE TRIGGER reject_image BEFORE INSERT ON image_favorites BEGIN SELECT RAISE(ABORT, 'injected image failure'); END;",
      );
      expect(
        () => runSqliteTransaction(db, writeAll, immediate: true),
        throwsA(isA<SqliteException>()),
      );
      expect(favorites.count('favorites'), 0);
      expect(history.count(), 0);
      expect(images.count(), 0);
      db.execute('DROP TRIGGER reject_image;');
      runSqliteTransaction(db, writeAll, immediate: true);
      expect(favorites.count('favorites'), 1);
      expect(history.find('book', 1)!.page, 2);
      expect(images.count(), 1);
      db.execute('BEGIN TRANSACTION;');
      history.removeMany([('book', 1)]);
      history.deleteWhere((id, type) => true);
      favorites.deleteFolder('favorites');
      images.saveAll([
        ImageFavoritesComic(
          'book',
          [],
          '',
          'source',
          [],
          [],
          DateTime(2026),
          '',
          {},
          '',
          1,
        ),
      ]);
      db.execute('ROLLBACK;');
      expect(favorites.count('favorites'), 1);
      expect(history.count(), 1);
      expect(images.count(), 1);
    },
  );
}
