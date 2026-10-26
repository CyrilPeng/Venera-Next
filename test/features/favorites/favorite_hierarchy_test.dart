import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorite_folder.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Database db;
  late FavoritesRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    repository = FavoritesRepository(db)..initializeMetadata();
  });
  tearDown(() => db.dispose());

  FavoriteItem comic(String id) => FavoriteItem.withTime(
    id: id,
    name: 'Comic $id',
    author: 'Artist',
    type: ComicType.local,
    tags: ['kept'],
    coverPath: 'cover',
    time: '2001-02-03 04:05:06',
  );

  void seed() {
    repository.initializeHierarchy();
    repository.createFolder('Parent');
    repository.createFolder('Other');
    repository.createFolder(
      'Child',
      parentId: repository.folderTree().named('Parent')!.id,
    );
  }

  test(
    'legacy migration preserves effective order, content, links and time',
    () {
      repository.createFolder('old/name');
      repository.createFolder('second');
      repository.updateOrder(['second', 'old/name']);
      repository.addComic(
        'old/name',
        comic('one'),
        translatedTags: 'translated',
        append: true,
      );
      repository.prepareForFollowUpdates('old/name', clearData: false);
      repository.updateUpdateTime('old/name', 'one', 0, 'chapter 2', 123);
      repository.linkFolderToNetwork('old/name', 'source', 'network');
      final schema = db
          .select("SELECT sql FROM sqlite_master WHERE name = 'old/name';")
          .single['sql'];
      final before = db
          .select('SELECT * FROM "old/name";')
          .map((row) => Map.of(row))
          .toList();
      repository.initializeHierarchy();
      final tree = repository.folderTree();
      expect(tree.roots.map((folder) => folder.name), ['second', 'old/name']);
      expect(tree.flattened.every((folder) => folder.parentId == null), isTrue);
      expect(repository.findLinked('old/name'), ('source', 'network'));
      expect(
        db.select('SELECT * FROM "old/name";').map((row) => Map.of(row)),
        before,
      );
      expect(
        db
            .select("SELECT sql FROM sqlite_master WHERE name = 'old/name';")
            .single['sql'],
        schema,
      );
      final ids = tree.flattened.map((folder) => folder.id).toList();
      repository.initializeHierarchy();
      expect(repository.folderTree().flattened.map((folder) => folder.id), ids);
      expect(repository.needsHierarchyMigration, isFalse);
    },
  );

  test('legacy duplicate and stale metadata retain effective root order', () {
    db.execute(
      'DROP TABLE folder_order; CREATE TABLE folder_order (folder_name TEXT, order_value INT);',
    );
    repository.createFolder('A');
    repository.createFolder('B');
    db.execute(
      "INSERT INTO folder_order VALUES ('B', -5), ('A', 8), ('A', -20), ('missing', NULL), (NULL, NULL);",
    );
    final before = repository.folderNames();
    repository.initializeHierarchy();
    expect(repository.folderNames(), before);
    expect(repository.folderTree().roots, hasLength(2));
  });

  test('failed migration rolls back schema, version and order', () {
    repository.createFolder('A');
    repository.updateOrder(['A']);
    db.execute(
      "CREATE TRIGGER fail_migration BEFORE INSERT ON folder_order BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
    );
    expect(repository.initializeHierarchy, throwsA(isA<SqliteException>()));
    expect(repository.needsHierarchyMigration, isTrue);
    expect(
      db.select('PRAGMA table_info(folder_order);').map((row) => row['name']),
      ['folder_name', 'order_value'],
    );
    expect(repository.folderNames(), ['A']);
    expect(repository.count('A'), 0);
    db.execute('DROP TRIGGER fail_migration;');
    repository.initializeHierarchy();
  });

  test(
    'both levels store comics and all view retains identity deduplication',
    () {
      seed();
      for (final folder in ['Parent', 'Child']) {
        repository.addComic(
          folder,
          comic('same'),
          translatedTags: '',
          append: true,
        );
      }
      expect(repository.count('Parent'), 1);
      expect(repository.count('Child'), 1);
      expect(repository.getAllComics(repository.folderNames()), hasLength(1));
      expect(repository.folderTree().label('Child'), 'Parent / Child');
    },
  );

  test('move and rename preserve identity, records and network link', () {
    seed();
    final before = repository.folderTree().named('Child')!;
    repository.addComic(
      'Child',
      comic('one'),
      translatedTags: '',
      append: true,
    );
    repository.linkFolderToNetwork('Child', 'source', 'remote');
    final other = repository.folderTree().named('Other')!;
    repository.moveFolder('Child', other.id);
    repository.renameFolder('Other', 'Renamed parent');
    repository.renameFolder('Child', 'Renamed child');
    final after = repository.folderTree().named('Renamed child')!;
    expect(after.id, before.id);
    expect(after.parentId, other.id);
    expect(
      repository.folderTree().label(after.name),
      'Renamed parent / Renamed child',
    );
    expect(repository.findLinked(after.name), ('source', 'remote'));
    expect(
      repository.findComic(after.name, 'one', 0)!.time,
      '2001-02-03 04:05:06',
    );
    repository.moveFolder(after.name, null);
    expect(repository.folderTree().named(after.name)!.parentId, isNull);
  });

  test(
    'reject self, third level, missing parent and moving a parent with children',
    () {
      seed();
      final tree = repository.folderTree();
      for (final action in <void Function()>[
        () => repository.moveFolder('Parent', tree.named('Parent')!.id),
        () => repository.moveFolder('Other', tree.named('Child')!.id),
        () => repository.moveFolder('Parent', tree.named('Other')!.id),
        () => repository.moveFolder('Child', 'missing'),
        () => repository.createFolder(
          'Grandchild',
          parentId: tree.named('Child')!.id,
        ),
      ]) {
        expect(action, throwsStateError);
      }
      expect(repository.folderNames(), ['Parent', 'Child', 'Other']);
    },
  );

  test('deletion never cascades and keeps another folder membership', () {
    seed();
    for (final folder in ['Parent', 'Child']) {
      repository.addComic(
        folder,
        comic('same'),
        translatedTags: '',
        append: true,
      );
    }
    expect(() => repository.deleteFolder('Parent'), throwsStateError);
    expect(repository.count('Child'), 1);
    repository.deleteFolder('Child');
    expect(repository.count('Parent'), 1);
    repository.deleteFolder('Parent');
    expect(repository.folderNames(), ['Other']);
  });

  test(
    'sorting preserves hierarchy and stable IDs; a partial failure rolls back',
    () {
      seed();
      repository.createFolder(
        'Child 2',
        parentId: repository.folderTree().named('Parent')!.id,
      );
      final before = repository.folderTree();
      repository.updateOrder(['Other', 'Child 2', 'Parent', 'Child']);
      expect(repository.folderNames(), ['Other', 'Parent', 'Child 2', 'Child']);
      for (final folder in before.flattened) {
        expect(repository.folderTree().named(folder.name)!.id, folder.id);
        expect(
          repository.folderTree().named(folder.name)!.parentId,
          folder.parentId,
        );
      }
      db.execute(
        "CREATE TRIGGER fail_sort BEFORE UPDATE ON folder_order WHEN NEW.folder_name = 'Child' BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
      );
      expect(
        () => repository.updateOrder(['Parent', 'Child', 'Child 2', 'Other']),
        throwsA(isA<SqliteException>()),
      );
      expect(repository.folderNames(), ['Other', 'Parent', 'Child 2', 'Child']);
    },
  );

  test('new-format corruption is rejected rather than silently flattened', () {
    seed();
    db.execute(
      "UPDATE folder_order SET parent_id = 'missing' WHERE folder_name = 'Child';",
    );
    expect(repository.initializeHierarchy, throwsFormatException);
    expect(repository.folderTree, throwsFormatException);
    expect(repository.count('Child'), 0);
  });

  test('future versions and missing modern columns are rejected', () {
    db.execute('PRAGMA user_version = 2;');
    expect(repository.initializeHierarchy, throwsFormatException);
    db.execute('PRAGMA user_version = 1;');
    expect(repository.initializeHierarchy, throwsFormatException);
  });

  test('invalid hierarchy snapshot rejects duplicate IDs and cycles', () {
    expect(
      () => FavoriteFolderTree([
        const FavoriteFolder(id: 'A', name: 'A', order: 0, parentId: 'B'),
        const FavoriteFolder(id: 'B', name: 'B', order: 0, parentId: 'A'),
      ]),
      throwsFormatException,
    );
    expect(
      () => FavoriteFolderTree([
        const FavoriteFolder(id: 'A', name: 'A', order: 0),
        const FavoriteFolder(id: 'A', name: 'B', order: 0),
      ]),
      throwsFormatException,
    );
  });
}
