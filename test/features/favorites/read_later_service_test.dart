import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/favorites/read_later_service.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  test(
    'injected read-later service follows replaced storage and live settings',
    () async {
      final first = sqlite3.openInMemory();
      final second = sqlite3.openInMemory();
      var repository = FavoritesRepository(first)..initializeMetadata();
      Object? selected;
      var saves = 0;
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
        selectFolder: (folder) => selected = folder,
        createFolder: (folder) => repository.createFolder(folder),
        addFirst: (folder, comic) {
          repository.addComic(folder, comic, translatedTags: '', append: false);
        },
        remove: (folder, id, type) {
          repository.deleteComics([folder], [(id, type.value)]);
        },
        saveSettings: () async {
          saves++;
        },
      );
      try {
        repository.createFolder('Later');
        await service.set(item, included: true, folderName: 'Later');
        expect(selected, 'Later (2)');
        expect(service.contains('id', ComicType(1)), isTrue);
        expect(service.comics(limit: 0), isEmpty);
        repository = FavoritesRepository(second)..initializeMetadata();
        expect(service.folder, isNull);
        expect(service.comics(), isEmpty);
        selected = 123;
        await service.set(item, included: false, folderName: 'Later');
        expect(repository.folderNames(), isEmpty);
        await service.set(item, included: true, folderName: 'Later');
        expect(selected, 'Later');
        expect(service.comics().single.id, 'id');
        expect(FavoritesRepository(first).count('Later (2)'), 1);
        expect(saves, 3);
      } finally {
        first.dispose();
        second.dispose();
      }
    },
  );
}
