import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/favorites/read_later_service.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test('failed member insertion rolls back the new folder', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    final repository = _FailingInsertRepository(db)..initializeMetadata();
    final service = ReadLaterService(
      repository: () => repository,
      configuredFolder: () => null,
      translateTags: (_) => '',
    );
    final item = FavoriteItem(
      id: 'bad',
      name: '',
      author: '',
      coverPath: '',
      type: ComicType.local,
      tags: [],
    );
    expect(
      () => service.set(item, included: true, folderName: 'Later'),
      throwsA(isA<SqliteException>()),
    );
    expect(repository.folderNames(), isEmpty);
    expect(db.autocommit, isTrue);
  });

  test(
    'injected read-later service follows replaced storage and live settings',
    () async {
      final first = sqlite3.openInMemory();
      final second = sqlite3.openInMemory();
      var repository = FavoritesRepository(first)..initializeMetadata();
      Object? selected;
      final item = FavoriteItem(
        id: 'id',
        name: 'Title',
        author: '',
        coverPath: '',
        type: ComicType(1),
        tags: [],
      );
      final service = ReadLaterService(
        repository: () => repository,
        configuredFolder: () => selected,
        translateTags: (_) => '',
      );
      try {
        repository.createFolder('Later');
        final firstCommit = service.set(
          item,
          included: true,
          folderName: 'Later',
        );
        expect(selected, isNull);
        expect(firstCommit.created, isTrue);
        expect(firstCommit.added, isTrue);
        selected = firstCommit.folder;
        expect(selected, 'Later (2)');
        expect(service.contains('id', ComicType(1)), isTrue);
        expect(service.comics(limit: 0), isEmpty);
        repository = FavoritesRepository(second)..initializeMetadata();
        expect(service.folder, isNull);
        expect(service.comics(), isEmpty);
        selected = 123;
        final noRemoval = service.set(
          item,
          included: false,
          folderName: 'Later',
        );
        expect(noRemoval.removed, isFalse);
        expect(repository.folderNames(), isEmpty);
        selected = service
            .set(item, included: true, folderName: 'Later')
            .folder;
        expect(selected, 'Later');
        expect(service.comics().single.id, 'id');
        expect(FavoritesRepository(first).count('Later (2)'), 1);
      } finally {
        first.dispose();
        second.dispose();
      }
    },
  );
}

class _FailingInsertRepository extends FavoritesRepository {
  _FailingInsertRepository(super.db);
  @override
  void createFolder(String folder) {
    super.createFolder(folder);
    db.execute('''CREATE TRIGGER fail_insert BEFORE INSERT ON "$folder"
      BEGIN SELECT RAISE(ABORT, 'insertion failed'); END;''');
  }
}
