import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/history/history_repository.dart';
import 'package:venera_next/features/history/image_favorites_repository.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

History historyItem(String id) => History(
  type: ComicType(1),
  id: id,
  maxPage: 20,
  ep: 2,
  page: 3,
  time: DateTime.fromMillisecondsSinceEpoch(1234),
  title: 'Title',
  subtitle: 'Author',
  cover: 'cover',
  readEpisode: {'2'},
  readDurationMs: 0,
);
ImageFavoritesComic imageItem(String id) => ImageFavoritesComic(
  id,
  [
    ImageFavoritesEp(
      'chapter',
      1,
      [ImageFavorite(1, 'key', null, 'chapter', id, 1, 'source', 'Chapter')],
      'Chapter',
      5,
    ),
  ],
  'Image title',
  'source',
  ['tag'],
  ['translated'],
  DateTime.fromMillisecondsSinceEpoch(1234),
  'author',
  {},
  '',
  5,
);

void main() {
  late Directory root;
  late Database db;
  const alias = '历史 "archive"';
  const quoted = '"历史 ""archive"""';
  setUp(() {
    root = Directory.systemTemp.createTempSync('attached-history-');
    db = sqlite3.open('${root.path}/main.db');
    db.execute('ATTACH DATABASE ? AS $quoted;', ['${root.path}/history.db']);
  });
  tearDown(() {
    db.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'all attached history operations and old-column migration isolate main',
    () {
      final main = HistoryRepository(db)..initialize();
      main.importHistory(historyItem('same'));
      main.addReadDuration(historyItem('same'), 99);
      final before = db
          .select('SELECT * FROM main.history;')
          .map((row) => row.values.toList())
          .toList();
      db.execute(
        'CREATE TABLE $quoted.history (id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT, time INT, type INT, ep INT, page INT, readEpisode TEXT, max_page INT);',
      );
      final attached = HistoryRepository(db, schema: alias)..initialize();
      attached.initialize();
      attached.importHistory(historyItem('same'));
      final changed = historyItem('same')..page = 9;
      attached.writeProgress(changed);
      attached.updateMetadata('same', 1, title: 'Imported');
      attached.addReadDuration(changed, 50);
      attached.addReadDuration(historyItem('duration-new'), 20);
      expect(attached.find('same', 1)!.title, 'Imported');
      expect(attached.find('same', 1)!.page, 9);
      expect(attached.getTotalReadDurationMs(), 70);
      expect(attached.countWithReadDuration(), 2);
      expect(attached.getAllByReadDuration().map((item) => item.id), [
        'same',
        'duration-new',
      ]);
      expect(attached.getAll(), hasLength(2));
      expect(attached.getRecent(), hasLength(2));
      expect(attached.identities(id: 'same'), [('same', 1)]);
      expect(attached.identities().toSet(), {('same', 1), ('duration-new', 1)});
      attached.remove('duration-new', 1);
      attached.importHistory(historyItem('batch'));
      attached.removeMany([('batch', 1)]);
      attached.importHistory(historyItem('predicate'));
      attached.deleteWhere((id, type) => id == 'predicate');
      expect(attached.count(), 1);
      attached.clearBefore(1235);
      expect(attached.count(), 0);
      attached.importHistory(historyItem('last'));
      attached.clear();
      expect(attached.count(), 0);
      expect(
        db
            .select('SELECT * FROM main.history;')
            .map((row) => row.values.toList())
            .toList(),
        before,
      );
      expect(
        db
            .select('PRAGMA $quoted.table_info(history);')
            .map((row) => row['name']),
        containsAll(['chapter_group', 'read_duration_ms']),
      );
    },
  );

  test(
    'image queries, deletion and batch writes stay in the selected schema',
    () {
      final main = ImageFavoritesRepository(db)..initialize();
      main.save(imageItem('same'));
      final before = db
          .select('SELECT * FROM main.image_favorites;')
          .single
          .values
          .toList();
      final attached = ImageFavoritesRepository(db, schema: alias)
        ..initialize();
      attached.saveAll([imageItem('same'), imageItem('new')]);
      expect(attached.count(), 2);
      expect(attached.getAll('translated'), hasLength(2));
      expect(attached.find('new', 'source'), isNotNull);
      final remove = imageItem('same')..imageFavoritesEp.clear();
      attached.save(remove);
      expect(attached.find('same', 'source'), isNull);
      expect(attached.getAll().single.id, 'new');
      expect(
        db.select('SELECT * FROM main.image_favorites;').single.values.toList(),
        before,
      );
      expect(
        () => HistoryRepository(
          db,
          schema: 'missing"; DROP TABLE image_favorites; --',
        ).initialize(),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => ImageFavoritesRepository(
          db,
          schema: 'missing',
        ).save(imageItem('bad')),
        throwsA(isA<SqliteException>()),
      );
      expect(main.count(), 1);
    },
  );

  test('one file-backed transaction rolls back both databases then retries', () {
    final favorites = FavoritesRepository(db)..initializeMetadata();
    final history = HistoryRepository(db, schema: alias)..initialize();
    final images = ImageFavoritesRepository(db, schema: alias)..initialize();
    db.execute(
      "CREATE TRIGGER $quoted.reject_image BEFORE INSERT ON image_favorites BEGIN SELECT RAISE(ABORT, 'injected'); END;",
    );
    void writeAll() => runSqliteTransaction(db, () {
      favorites.createFolder('imported');
      favorites.addComic(
        'imported',
        FavoriteItem(
          id: 'book',
          name: 'Title',
          author: '',
          coverPath: '',
          type: ComicType(1),
          tags: [],
        ),
        translatedTags: '',
        append: true,
      );
      history.importHistory(historyItem('book'));
      images.saveAll([imageItem('book')]);
    }, immediate: true);
    expect(writeAll, throwsA(isA<SqliteException>()));
    expect(favorites.folderNames(), isEmpty);
    expect(history.count(), 0);
    expect(images.count(), 0);
    db.execute('DROP TRIGGER $quoted.reject_image;');
    writeAll();
    // Independent connections verify committed data in the intended files.
    final mainCheck = sqlite3.open(
      '${root.path}/main.db',
      mode: OpenMode.readOnly,
    );
    final historyCheck = sqlite3.open(
      '${root.path}/history.db',
      mode: OpenMode.readOnly,
    );
    try {
      expect(
        FavoritesRepository(mainCheck).getFolderComics('imported').single.id,
        'book',
      );
      expect(HistoryRepository(historyCheck).find('book', 1)!.page, 3);
      expect(
        ImageFavoritesRepository(historyCheck).find('book', 'source'),
        isNotNull,
      );
      expect(
        mainCheck.select(
          "SELECT name FROM sqlite_master WHERE name IN ('history', 'image_favorites');",
        ),
        isEmpty,
      );
    } finally {
      mainCheck.dispose();
      historyCheck.dispose();
    }
  });
}
