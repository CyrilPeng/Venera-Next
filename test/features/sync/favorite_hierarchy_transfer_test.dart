import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/network/cookie_jar.dart';

FavoriteItem _comic(String id) => FavoriteItem.withTime(
  id: id,
  name: id,
  author: 'Artist',
  type: ComicType.local,
  tags: ['kept'],
  coverPath: '',
  time: '2001-02-03 04:05:06',
);

void main() {
  late Directory root;
  late LocalFavoritesManager manager;
  late AppdataImportCheckpoint checkpoint;
  setUp(() async {
    checkpoint = appdata.captureImportCheckpoint();
    root = Directory.systemTemp.createTempSync('favorite-hierarchy-transfer-');
    App.dataPath = (Directory('${root.path}/data')..createSync()).path;
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    Directory('${App.dataPath}/comic_source').createSync();
    for (final name in ['history.db', 'cookie.db']) {
      final db = sqlite3.open('${App.dataPath}/$name');
      db.execute('CREATE TABLE seed (id INT);');
      db.dispose();
    }
    manager = LocalFavoritesManager();
    await manager.init();
  });
  tearDown(() async {
    await manager.closeAndWait();
    await appdata.saveData(false);
    await appdata.restoreImportCheckpoint(checkpoint, persist: false);
    await HistoryManager.cache?.waitForAsyncWrites();
    HistoryManager.cache?.close();
    SingleInstanceCookieJar.instance?.dispose();
    root.deleteSync(recursive: true);
  });

  File archiveDatabase(void Function(FavoritesRepository) seed) {
    final path = '${root.path}/incoming.db';
    final db = sqlite3.open(path);
    try {
      final repository = FavoritesRepository(db)..initializeMetadata();
      seed(repository);
    } finally {
      db.dispose();
    }
    final file = File('${root.path}/incoming.venera');
    final zip = ZipFile.open(file.path);
    zip.addFile('local_favorite.db', path);
    zip.close();
    return file;
  }

  test(
    'complete backups and sync snapshots retain both levels, IDs, direct contents and preferences after restart',
    () async {
      await manager.createFolder('Parent');
      await manager.createFolder('Other');
      final parent = manager.folderTree.named('Parent')!;
      await manager.createChildFolder('Child', parent.id);
      await manager.addComic('Parent', _comic('same'));
      await manager.addComic('Child', _comic('same'));
      await manager.addComic('Child', _comic('child-only'));
      await manager.linkFolderToNetwork('Child', 'source', 'remote');
      await manager.prepareTableForFollowUpdates(
        'Child',
        generation: manager.connectionGeneration,
        isCurrent: () => true,
      );
      await manager.updateUpdateTime(
        'Child',
        'child-only',
        ComicType.local,
        '2026-10-25',
      );
      final checkedAt = manager
          .getComicsWithUpdatesInfo('Child')
          .singleWhere((comic) => comic.id == 'child-only')
          .lastCheckTime;
      await appdata.updateSettings((draft) {
        draft['quickFavorite'] = 'Child';
        draft['followUpdatesFolder'] = 'Child';
        draft['readLaterFolder'] = 'Child';
      });
      await manager.rename('Parent', 'Renamed parent');
      final singleFolder =
          jsonDecode(manager.folderToJson('Renamed parent')) as Map;
      expect(
        (singleFolder['comics'] as List).map((comic) => (comic as Map)['id']),
        ['same'],
      );
      expect(singleFolder.keys, unorderedEquals(['info', 'name', 'comics']));
      final ids = {
        for (final folder in manager.folderTree.flattened)
          folder.name: folder.id,
      };
      final backup = await exportAppData(sync: false);
      final syncSnapshot = File('${root.path}/sync.venera');
      await exportSyncAppData(excludeFields: true, destination: syncSnapshot);
      for (final snapshot in [backup, syncSnapshot]) {
        await manager.moveFolder(
          'Child',
          manager.folderTree.named('Other')!.id,
        );
        expect(await importAppData(snapshot), DataSyncCommitState.applied);
        for (var attempt = 0; attempt < 2; attempt++) {
          expect(manager.folderTree.label('Child'), 'Renamed parent / Child');
          expect({
            for (final folder in manager.folderTree.flattened)
              folder.name: folder.id,
          }, ids);
          expect(
            manager.getFolderComics('Renamed parent').map((comic) => comic.id),
            ['same'],
          );
          expect(manager.getFolderComics('Child'), hasLength(2));
          expect(manager.totalComics, 2);
          expect(manager.findLinked('Child'), ('source', 'remote'));
          final tracked = manager
              .getComicsWithUpdatesInfo('Child')
              .singleWhere((comic) => comic.id == 'child-only');
          expect(tracked.hasNewUpdate, isTrue);
          expect(tracked.updateTime, '2026-10-25');
          expect(tracked.lastCheckTime, checkedAt);
          expect(appdata.settings['quickFavorite'], 'Child');
          expect(appdata.settings['followUpdatesFolder'], 'Child');
          expect(manager.readLaterFolder, 'Child');
          expect(manager.getReadLaterComics(), hasLength(2));
          expect(
            manager.getFolderComics('Child').first.time,
            '2001-02-03 04:05:06',
          );
          if (attempt == 0) {
            await manager.closeAndWait();
            await manager.init();
          }
        }
      }
    },
  );

  test(
    'legacy full backup and single-folder JSON import remain first-level without parsing names',
    () async {
      final incoming = archiveDatabase((repository) {
        repository.createFolder('old/name');
        repository.createFolder('second');
        repository.updateOrder(['second', 'old/name']);
        repository.addComic(
          'old/name',
          _comic('kept'),
          translatedTags: '',
          append: true,
        );
      });
      await importAppData(incoming);
      expect(manager.folderNames, ['second', 'old/name']);
      expect(manager.folderTree.roots, hasLength(2));
      final parent = manager.folderTree.named('second')!;
      await manager.createChildFolder('Existing child', parent.id);
      final json = jsonEncode({
        'name': 'old/name',
        'comics': [_comic('new').toJson()],
      });
      await manager.fromJson(json);
      final imported = manager.folderTree.named('old/name(0)')!;
      expect(imported.parentId, isNull);
      expect(manager.folderTree.named('Existing child')!.parentId, parent.id);
      expect(manager.getFolderComics(imported.name).single.id, 'new');
    },
  );

  for (final futureVersion in [false, true]) {
    test(
      'invalid incoming hierarchy is rejected before replacing any live data; future=$futureVersion',
      () async {
        await manager.createFolder('Original');
        await manager.addComic('Original', _comic('original'));
        final incoming = archiveDatabase((repository) {
          repository.initializeHierarchy();
          repository.createFolder('Incoming');
          if (futureVersion) {
            repository.db.execute('PRAGMA user_version = 2;');
          } else {
            repository.db.execute(
              "UPDATE folder_order SET parent_id = 'missing';",
            );
          }
        });
        final generation = manager.connectionGeneration;
        final original = File(
          '${App.dataPath}/local_favorite.db',
        ).readAsBytesSync();
        final settings = jsonEncode(appdata.toJson());
        await expectLater(importAppData(incoming), throwsFormatException);
        expect(manager.connectionGeneration, generation);
        expect(
          File('${App.dataPath}/local_favorite.db').readAsBytesSync(),
          original,
        );
        expect(jsonEncode(appdata.toJson()), settings);
        expect(manager.getFolderComics('Original').single.id, 'original');
        expect(manager.folderNames, isNot(contains('Incoming')));
      },
    );
  }
}
