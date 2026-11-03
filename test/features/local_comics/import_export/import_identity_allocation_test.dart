import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const folder = 'Imports';
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9ZkAAAAASUVORK5CYII=',
  );
  late Directory root;
  late Directory source;
  late LocalManager manager;
  late LocalFavoritesManager favorites;
  late ComicImportService service;
  Object? oldFollow;
  Object? oldQuick;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('import-identity-');
    App.dataPath = root.path;
    App.cachePath = (Directory(p.join(root.path, 'cache'))..createSync()).path;
    oldFollow = appdata.settings['followUpdatesFolder'];
    oldQuick = appdata.settings['quickFavorite'];
    LocalManager.current?.dispose();
    manager = LocalManager(initializeSources: () async {});
    await manager.init();
    favorites = LocalFavoritesManager();
    await favorites.init();
    await favorites.createFolder(folder);
    await favorites.createFolder('Old favorites');
    service = ComicImportService(
      localManager: () => manager,
      favoritesManager: () => favorites,
    );
    source = Directory(p.join(root.path, 'source'))..createSync();
    for (final name in ['Fresh A', 'Fresh B']) {
      File(p.join(source.path, name, '1.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(png);
    }
  });

  tearDown(() async {
    App.dataPath = root.path;
    await manager.pendingDownloadTaskWrites;
    manager.dispose();
    await favorites.debugWaitForHashedIdsRefresh();
    await appdata.saveData(false);
    favorites.close();
    appdata.settings['followUpdatesFolder'] = oldFollow;
    appdata.settings['quickFavorite'] = oldQuick;
    final target = root.resolveSymbolicLinksSync();
    expect(
      p.isWithin(Directory.systemTemp.resolveSymbolicLinksSync(), target),
      isTrue,
    );
    expect(p.basename(target), startsWith('import-identity-'));
    Directory(target).deleteSync(recursive: true);
  });

  FavoriteItem oldComic(String id, {ComicType type = ComicType.local}) =>
      FavoriteItem(
        id: id,
        name: 'Unrelated old book $id',
        coverPath: '/previous/device/cover.png',
        author: 'Original author',
        type: type,
        tags: ['original'],
        favoriteTime: DateTime(2024, 1, 2),
      );

  Future<ComicImportResult> importFolders({String? selectedFolder}) =>
      service.runImport(
        (operation) => operation.directory(
          source,
          single: false,
          copy: true,
          folder: selectedFolder,
        ),
      );

  String oldRows() {
    final database = sqlite3.open(
      p.join(root.path, 'local_favorite.db'),
      mode: OpenMode.readOnly,
    );
    try {
      return jsonEncode([
        for (final name in [folder, 'Old favorites'])
          for (final row in database.select(
            'SELECT * FROM "$name" WHERE id IN (?, ?)',
            ['1', '4'],
          ))
            Map<String, Object?>.from(row),
      ]);
    } finally {
      database.dispose();
    }
  }

  for (final selected in [null, folder, 'Old favorites']) {
    test(
      'migrated identities in all folders survive new imports; selected=$selected',
      () async {
        await favorites.addComic(folder, oldComic('1'));
        await favorites.addComic('Old favorites', oldComic('4'));
        await favorites.addComic(
          'Old favorites',
          oldComic('900', type: const ComicType(17)),
        );
        final original = oldRows();
        expect(manager.count, 0);
        final result = await importFolders(selectedFolder: selected);
        expect(result.succeeded, isTrue);
        expect(result.importedCount, 2);
        expect(result.issues, isEmpty);
        expect(oldRows(), original);
        expect(manager.find('1', ComicType.local), isNull);
        expect(manager.find('4', ComicType.local), isNull);
        expect(
          manager
              .getComics(LocalSortType.name)
              .map((comic) => comic.id)
              .toSet(),
          {'5', '6'},
        );
        for (final title in ['Fresh A', 'Fresh B']) {
          final comic = manager.findByName(title)!;
          expect(
            favorites.find(comic.id, ComicType.local),
            selected == null ? isEmpty : [selected],
          );
          expect(
            File(p.join(source.path, title, '1.png')).readAsBytesSync(),
            png,
          );
        }
        await manager.pendingDownloadTaskWrites;
        manager.dispose();
        manager = LocalManager(initializeSources: () async {});
        await manager.init();
        expect(manager.count, 2);
        expect(oldRows(), original);
      },
    );
  }

  test(
    'allocation uses persisted IDs even if the favorite UI index is stale',
    () async {
      final database = sqlite3.open(p.join(root.path, 'local_favorite.db'));
      try {
        FavoritesRepository(database).addComic(
          'Old favorites',
          oldComic('30'),
          translatedTags: 'original',
          append: true,
        );
      } finally {
        database.dispose();
      }
      expect(favorites.isExist('30', ComicType.local), isFalse);
      final result = await importFolders(selectedFolder: folder);
      expect(result.importedCount, 2);
      expect(
        manager.getComics(LocalSortType.name).map((comic) => comic.id).toSet(),
        {'31', '32'},
      );
      expect(
        favorites.getFolderComics('Old favorites').single.name,
        'Unrelated old book 30',
      );
    },
  );

  test(
    'plain allocation belongs to the original local store, not a later global data path',
    () async {
      await favorites.addComic('Old favorites', oldComic('8'));
      App.dataPath = (Directory(
        p.join(root.path, 'replacement'),
      )..createSync()).path;
      expect(manager.findValidId(ComicType.local), '9');
      expect(Directory(App.dataPath).listSync(), isEmpty);
    },
  );

  test(
    'concurrent accepted registrations allocate unique IDs without overwriting old records',
    () async {
      await favorites.addComic('Old favorites', oldComic('1'));
      final original = oldRows();
      await Future.wait([
        for (var index = 0; index < 12; index++)
          service.registerComic(
            LocalComic(
              id: '0',
              title: 'New $index',
              subtitle: '',
              tags: [],
              directory: 'New $index',
              chapters: null,
              cover: '1.png',
              comicType: ComicType.local,
              downloadedChapters: [],
              createdAt: DateTime(2026),
            ),
            folder: index.isEven ? folder : null,
          ),
      ]);
      final comics = manager.getComics(LocalSortType.name);
      expect(comics, hasLength(12));
      expect(comics.map((comic) => comic.id).toSet(), {
        for (var id = 2; id < 14; id++) '$id',
      });
      expect(favorites.getFolderComics(folder), hasLength(6));
      expect(oldRows(), original);
    },
  );

  test('a real storage failure is not relabeled as no valid comics', () async {
    final database = sqlite3.open(p.join(root.path, 'local.db'));
    try {
      database.execute(
        "CREATE TRIGGER reject BEFORE INSERT ON comics BEGIN SELECT RAISE(ABORT, 'storage failure'); END;",
      );
    } finally {
      database.dispose();
    }
    final result = await importFolders(selectedFolder: folder);
    expect(result.succeeded, isFalse);
    expect(result.importedCount, 0);
    expect(result.issues.map((issue) => issue.kind), [
      ComicImportIssueKind.registrationFailed,
    ]);
    expect(manager.count, 0);
    expect(favorites.getFolderComics(folder), isEmpty);
  });
}
