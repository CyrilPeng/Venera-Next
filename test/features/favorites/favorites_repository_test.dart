import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';

void main() {
  late Database db;
  late FavoritesRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    repository = FavoritesRepository(db);
    db.execute(
      'CREATE TABLE folder_order (folder_name TEXT, order_value INT);',
    );
    db.execute('CREATE TABLE folder_sync (folder_name TEXT);');
    for (final name in ['first', 'second', 'empty', '收藏 "A"']) {
      final table = '"${name.replaceAll('"', '""')}"';
      db.execute('''CREATE TABLE $table (
        id TEXT, type INT, name TEXT, author TEXT, tags TEXT,
        cover_path TEXT, time TEXT, display_order INT,
        PRIMARY KEY (id, type)
      );''');
    }
    db.execute(
      "INSERT INTO first VALUES ('same', 1, 'First title', '', 'a', 'cover', 'old time', 20);",
    );
    db.execute(
      "INSERT INTO first VALUES ('other', 1, 'Other title', '', '', '', 'old time', -3);",
    );
    db.execute(
      "INSERT INTO second VALUES ('same', 1, 'Duplicate title', '', '', '', 'old time', 0);",
    );
    db.execute(
      "INSERT INTO second VALUES ('same', 2, 'Other source', '', '', '', 'old time', 1);",
    );
  });
  tearDown(() => db.dispose());

  test(
    'single move prepends and leaves duplicate destination/source intact',
    () {
      expect(repository.moveFavorite('first', 'second', 'same', 1), isFalse);
      expect(repository.findComic('first', 'same', 1)!.name, 'First title');
      expect(
        repository.findComic('second', 'same', 1)!.name,
        'Duplicate title',
      );
      expect(repository.moveFavorite('first', 'second', 'other', 1), isTrue);
      expect(repository.comicExists('first', 'other', 1), isFalse);
      expect(repository.getFolderComics('second').first.id, 'other');
      expect(repository.minValue('second'), -1);
    },
  );

  test('single move rolls back destination when source deletion fails', () {
    db.execute(
      "CREATE TRIGGER reject_remove BEFORE DELETE ON first BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    expect(
      () => repository.moveFavorite('first', 'empty', 'other', 1),
      throwsA(isA<SqliteException>()),
    );
    expect(repository.count('empty'), 0);
    expect(repository.comicExists('first', 'other', 1), isTrue);
    db.execute('DROP TRIGGER reject_remove;');
    expect(repository.moveFavorite('first', 'empty', 'other', 1), isTrue);
  });

  test(
    'batch copy and move retain merge order and same-folder transfers do nothing',
    () {
      repository.copyMany('first', 'second', [('same', 1), ('other', 1)]);
      expect(repository.count('first'), 2);
      expect(
        repository.findComic('second', 'same', 1)!.name,
        'Duplicate title',
      );
      expect(repository.maxValue('second'), 3);
      repository.moveMany('first', 'second', [('same', 1), ('other', 1)]);
      expect(repository.count('first'), 0);
      expect(repository.count('second'), 3);
      repository.moveMany('second', 'second', [('same', 1), ('other', 1)]);
      repository.copyMany('second', 'second', [('same', 1)]);
      expect(repository.count('second'), 3);
    },
  );

  for (final moving in [false, true]) {
    test('batch transfer failure rolls back earlier rows; move=$moving', () {
      db.execute(
        "CREATE TRIGGER reject_insert BEFORE INSERT ON empty WHEN NEW.id = 'other' BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
      );
      void transfer() {
        final action = moving ? repository.moveMany : repository.copyMany;
        action('first', 'empty', [('same', 1), ('other', 1)]);
      }

      expect(transfer, throwsA(isA<SqliteException>()));
      expect(repository.count('empty'), 0);
      expect(repository.count('first'), 2);
      db.execute('DROP TRIGGER reject_insert;');
      transfer();
      expect(repository.count('empty'), 2);
      expect(repository.count('first'), moving ? 0 : 2);
    });
  }

  test(
    'folder ordering excludes metadata and retains default/first stored order',
    () {
      db.execute(
        "INSERT INTO folder_order VALUES ('second', -5), ('first', 8), ('first', -20), ('missing', NULL), (NULL, NULL);",
      );
      final folders = repository.folderNames();
      expect(folders.first, 'second');
      expect(folders.last, 'first');
      expect(folders.toSet(), {'first', 'second', 'empty', '收藏 "A"'});
    },
  );

  test('folder queries preserve order, identity and empty folder defaults', () {
    expect(repository.getFolderComics('first').map((item) => item.id), [
      'other',
      'same',
    ]);
    expect(repository.count('first'), 2);
    expect(repository.minValue('first'), -3);
    expect(repository.maxValue('first'), 20);
    expect(repository.minValue('empty'), 0);
    expect(repository.maxValue('empty'), 0);
    expect(repository.getFolderComics('收藏 "A"'), isEmpty);
    expect(repository.comicExists('first', 'same', 2), isFalse);
    expect(repository.findComic('first', "' OR 1 = 1 --", 1), isNull);
    expect(repository.findComic('first', 'same', 1)!.time, 'old time');
    expect(repository.findFolders(['second', 'first'], 'same', 1), [
      'second',
      'first',
    ]);
    expect(repository.findFolders(['second', 'first'], 'same', 2), ['second']);
  });

  test(
    'aggregate deduplication keeps the first folder while folder views keep copies',
    () {
      final unique = repository.getAllComics(['first', 'second']);
      expect(unique, hasLength(3));
      expect(
        unique
            .singleWhere((item) => item.id == 'same' && item.type.value == 1)
            .name,
        'First title',
      );
      expect(
        unique.singleWhere((item) => item.type.value == 2).name,
        'Other source',
      );
      final all = repository.allComics(['first', 'second']);
      expect(all, hasLength(4));
      expect(
        all
            .where((item) => item.id == 'same' && item.type.value == 1)
            .map((item) => item.folder),
        ['first', 'second'],
      );
    },
  );
}
