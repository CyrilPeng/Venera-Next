import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/favorites/folder_name_validation.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Database db;
  late FavoritesRepository repository;
  setUp(() {
    db = sqlite3.openInMemory();
    repository = FavoritesRepository(db)
      ..initializeMetadata()
      ..initializeHierarchy();
  });
  tearDown(() => db.dispose());

  test('validation rejects ASCII collisions and allows changing own case', () {
    expect(validateFolderName('IP', folders: ['ip']), isNotNull);
    expect(
      validateFolderName('IP', folders: ['ip', 'Other'], currentName: 'ip'),
      isNull,
    );
    expect(
      validateFolderName('OTHER', folders: ['ip', 'Other'], currentName: 'ip'),
      isNotNull,
    );
    expect(validateFolderName('ä', folders: ['Ä']), isNull);
    repository.createFolder('Ä');
    repository.createFolder('ä');
    expect(repository.folderNames(), ['Ä', 'ä']);
  });

  test('case-only rename preserves hierarchy, content, links and updates', () {
    repository.createFolder('ip');
    final id = repository.folderTree().named('ip')!.id;
    repository.createFolder('Child', parentId: id);
    repository.addComic(
      'ip',
      FavoriteItem.withTime(
        id: 'same',
        name: 'Saved comic',
        author: 'Artist',
        type: ComicType.local,
        tags: ['kept'],
        coverPath: 'cover',
        time: '2001-02-03 04:05:06',
      ),
      translatedTags: 'translated',
      append: true,
    );
    repository.prepareForFollowUpdates('ip', clearData: false);
    repository.updateUpdateTime('ip', 'same', 0, 'chapter 2', 123);
    repository.linkFolderToNetwork('ip', 'source', 'network');
    final before = db.select('SELECT * FROM ip;').map(Map.of).toList();

    repository.renameFolder('ip', 'IP');

    expect(repository.folderNames(), ['IP', 'Child']);
    expect(repository.folderTree().named('IP')!.id, id);
    expect(repository.folderTree().named('Child')!.parentId, id);
    expect(repository.findLinked('IP'), ('source', 'network'));
    expect(repository.findLinked('ip'), (null, null));
    expect(db.select('SELECT * FROM IP;').map(Map.of), before);
    expect(repository.countUpdates('IP'), 1);
    repository.initializeHierarchy();
    repository.renameFolder('IP', 'ip');
    expect(repository.folderTree().named('ip')!.id, id);
  });

  test('failed case-only rename rolls back the table and all metadata', () {
    repository.createFolder('ip');
    repository.linkFolderToNetwork('ip', 'source', 'network');
    db.execute('''
      CREATE TRIGGER reject_rename BEFORE UPDATE ON folder_sync
      BEGIN SELECT RAISE(ABORT, 'blocked'); END;
    ''');
    expect(
      () => repository.renameFolder('ip', 'IP'),
      throwsA(isA<SqliteException>()),
    );
    expect(repository.folderNames(), ['ip']);
    expect(repository.findLinked('ip'), ('source', 'network'));
    expect(
      db
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((row) => row['name']),
      unorderedEquals(['folder_order', 'folder_sync', 'ip']),
    );
    repository.initializeHierarchy();
    db.execute('DROP TRIGGER reject_rename;');
    repository.renameFolder('ip', 'IP');
    expect(repository.folderNames(), ['IP']);
  });
}
