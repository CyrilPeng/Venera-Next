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
    db.execute(
      'CREATE TABLE folder_sync (folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT);',
    );
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
    'folder rename preserves order and replaces exact network associations',
    () {
      db.execute("INSERT INTO folder_order VALUES ('first', 8);");
      repository.linkFolderToNetwork('first', 'source', "remote's folder");
      repository.linkFolderToNetwork('first', 'updated', 'remote');
      expect(
        repository.isLinkedToNetworkFolder(
          'first',
          'source',
          "remote's folder",
        ),
        isFalse,
      );
      repository.renameFolder('first', 'renamed');
      expect(repository.count('renamed'), 2);
      expect(repository.findLinked('first'), (null, null));
      expect(repository.findLinked('renamed'), ('updated', 'remote'));
      expect(
        db
            .select(
              "SELECT order_value FROM folder_order WHERE folder_name = 'renamed'",
            )
            .single['order_value'],
        8,
      );
      repository.deleteFolder('renamed');
      repository.createFolder('renamed');
      expect(repository.count('renamed'), 0);
      expect(repository.findLinked('renamed'), (null, null));
    },
  );

  for (final deleting in [false, true]) {
    test(
      'network metadata failure rolls back folder changes; delete=$deleting',
      () {
        db.execute("INSERT INTO folder_order VALUES ('first', 8);");
        repository.linkFolderToNetwork('first', 'source', 'remote');
        db.execute(
          "CREATE TRIGGER reject_sync BEFORE ${deleting ? 'DELETE' : 'UPDATE'} ON folder_sync BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
        );
        void change() {
          if (deleting) {
            repository.deleteFolder('first');
          } else {
            repository.renameFolder('first', 'renamed');
          }
        }

        expect(change, throwsA(isA<SqliteException>()));
        expect(repository.count('first'), 2);
        expect(repository.folderNames(), isNot(contains('renamed')));
        expect(repository.findLinked('first'), ('source', 'remote'));
        expect(
          db
              .select(
                "SELECT order_value FROM folder_order WHERE folder_name = 'first'",
              )
              .single['order_value'],
          8,
        );
        db.execute('DROP TRIGGER reject_sync;');
        change();
        expect(repository.folderNames(), isNot(contains('first')));
      },
    );
  }

  test('cross-folder deletion rolls back and reports only actual identities', () {
    db.execute(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON second BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    final ids = [('same', 1), ('same', 1), ('absent', 1)];
    expect(
      () => repository.deleteComics(['first', 'second'], ids),
      throwsA(isA<SqliteException>()),
    );
    expect(repository.comicExists('first', 'same', 1), isTrue);
    expect(repository.comicExists('second', 'same', 1), isTrue);
    db.execute('DROP TRIGGER reject_delete;');
    expect(repository.deleteComics(['first', 'second'], ids), {
      'first': [('same', 1)],
      'second': [('same', 1)],
    });
    expect(repository.comicExists('second', 'same', 2), isTrue);
    expect(repository.deleteComics(['first', 'second'], ids), isEmpty);
  });

  test('folder drop rolls back when order cleanup fails', () {
    db.execute("INSERT INTO folder_order VALUES ('first', 1);");
    db.execute(
      "CREATE TRIGGER reject_order_delete BEFORE DELETE ON folder_order BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    expect(
      () => repository.deleteFolder('first'),
      throwsA(isA<SqliteException>()),
    );
    expect(repository.count('first'), 2);
    expect(db.select('SELECT * FROM folder_order'), hasLength(1));
    db.execute('DROP TRIGGER reject_order_delete;');
    repository.deleteFolder('first');
    expect(repository.folderNames(), isNot(contains('first')));
    expect(db.select('SELECT * FROM folder_order'), isEmpty);
  });

  test(
    'insertion selects explicit/front/end order and rejects duplicate identity',
    () {
      db.execute('ALTER TABLE first ADD COLUMN translated_tags TEXT;');
      final item = repository.findComic('first', 'same', 1)!..id = 'new';
      expect(
        repository.addComic(
          'first',
          item,
          translatedTags: 'translated',
          append: true,
          updateTime: 'ignored on legacy table',
        ),
        isTrue,
      );
      expect(repository.maxValue('first'), 21);
      expect(
        repository.addComic('first', item, translatedTags: '', append: false),
        isFalse,
      );
      item.id = 'front';
      expect(
        repository.addComic('first', item, translatedTags: '', append: false),
        isTrue,
      );
      expect(repository.minValue('first'), -4);
      item.id = 'explicit';
      repository.addComic(
        'first',
        item,
        translatedTags: '',
        append: false,
        order: 100,
      );
      expect(repository.maxValue('first'), 100);
      expect(repository.findComic('first', 'new', 1)!.time, 'old time');
      expect(
        db
            .select("SELECT translated_tags FROM first WHERE id = 'new'")
            .single['translated_tags'],
        'translated',
      );
    },
  );

  test('optional update time failure rolls back insertion and permits retry', () {
    db.execute('ALTER TABLE first ADD COLUMN translated_tags TEXT;');
    db.execute('ALTER TABLE first ADD COLUMN last_update_time TEXT;');
    db.execute(
      "CREATE TRIGGER reject_time BEFORE UPDATE OF last_update_time ON first BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    final item = repository.findComic('first', 'same', 1)!..id = 'new';
    bool add() => repository.addComic(
      'first',
      item,
      translatedTags: '',
      append: true,
      updateTime: '2026-10-01',
    );
    expect(add, throwsA(isA<SqliteException>()));
    expect(repository.findComic('first', 'new', 1), isNull);
    db.execute('DROP TRIGGER reject_time;');
    expect(add(), isTrue);
    expect(
      db
          .select("SELECT last_update_time FROM first WHERE id = 'new'")
          .single['last_update_time'],
      '2026-10-01',
    );
  });

  test('folder reorder failure rolls back earlier rows', () {
    db.execute(
      "CREATE TRIGGER reject_order BEFORE INSERT ON folder_order WHEN NEW.folder_name = 'second' BEGIN SELECT RAISE(ABORT, 'rejected'); END;",
    );
    expect(
      () => repository.updateOrder(['first', 'second']),
      throwsA(isA<SqliteException>()),
    );
    expect(db.select('SELECT * FROM folder_order'), isEmpty);
    db.execute('DROP TRIGGER reject_order;');
    repository.updateOrder(['second', 'first']);
    expect(
      db
          .select(
            "SELECT order_value FROM folder_order WHERE folder_name = 'first'",
          )
          .single['order_value'],
      1,
    );
  });

  test(
    'tag values are bound and information updates preserve order and time',
    () {
      repository.addTagTo('second', 'same', "author's");
      expect(repository.findComic('second', 'same', 1)!.tags, ["author's"]);
      expect(repository.findComic('second', 'same', 2)!.tags, ["author's"]);
      final item = repository.findComic('second', 'same', 1)!
        ..name = 'Changed'
        ..tags = ['b']
        ..time = 'not submitted';
      repository.updateInfo('second', item);
      expect(repository.findComic('second', 'same', 1)!.name, 'Changed');
      expect(repository.findComic('second', 'same', 2)!.name, 'Other source');
      expect(repository.findComic('second', 'same', 1)!.time, 'old time');
      expect(repository.minValue('second'), 0);
    },
  );

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
