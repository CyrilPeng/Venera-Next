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
