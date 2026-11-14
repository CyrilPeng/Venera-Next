import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import '../../support/legacy_favorites_fixture.dart';
import 'support/favorites_manager_fixture.dart';
import '../../support/sqlite_test_environment.dart';

void main() {
  test(
    'failed migration releases connection and allows explicit retry',
    () async {
      await withFavoritesManager((manager) async {
        await manager.debugWaitForHashedIdsRefresh();
        manager.close();
        final path = '${App.dataPath}/local_favorite.db';
        final db = sqlite3.open(path);
        db.execute('DROP TABLE folder_order;');
        db.execute('PRAGMA user_version = 0;');
        db.execute('CREATE TABLE folder_order (invalid TEXT);');
        db.dispose();
        final first = manager.init();
        final second = manager.init();
        await Future.wait([
          expectLater(first, throwsA(isA<SqliteException>())),
          expectLater(second, throwsA(isA<SqliteException>())),
        ]);
        expect(() => manager.folderNames, throwsStateError);
        // Windows will reject renaming a file with an unreleased SQLite handle.
        File(path).renameSync('$path.failed');
        File('$path.failed').renameSync(path);
        final repaired = sqlite3.open(path);
        repaired.execute('DROP TABLE folder_order;');
        repaired.dispose();
        await manager.init();
        expect(
          manager.folderNames,
          contains(LocalFavoritesManager.trackingFolderName),
        );
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'colliding legacy hashes retain independent favorite and update state',
    () async {
      await withFavoritesManager((manager) async {
        await manager.createFolder('identity-test');
        await manager.createFolder('identity-copy');
        appdata.settings['followUpdatesFolder'] = 'identity-test';
        await manager.prepareTableForFollowUpdates('identity-test');
        final first = managerFavorite('collision-first');
        final secondType = first.id.hashCode ^ 'collision-second'.hashCode;
        final second = FavoriteItem(
          id: 'collision-second',
          name: 'Second',
          coverPath: 'second.jpg',
          author: '',
          type: ComicType(secondType),
          tags: [],
        );
        expect(
          first.id.hashCode ^ first.type.value,
          second.id.hashCode ^ second.type.value,
        );
        await manager.addComic('identity-test', first);
        await manager.addComic('identity-test', second);
        manager.refreshHashedIds();
        // Commit both additions and removals while a snapshot is in flight.
        await manager.addComic('identity-copy', first);
        await manager.updateUpdateTime(
          'identity-test',
          first.id,
          first.type,
          'v1',
        );
        expect(manager.hasNewUpdate(second.id, second.type), isFalse);
        await manager.updateUpdateTime(
          'identity-test',
          second.id,
          second.type,
          'v2',
        );
        await manager.markAsRead(first.id, first.type);
        expect(manager.hasNewUpdate(second.id, second.type), isTrue);
        await manager.deleteComicWithId('identity-test', first.id, first.type);
        expect(manager.isExist(first.id, first.type), isTrue);
        await manager.debugWaitForHashedIdsRefresh();
        expect(manager.totalComics, 2);
        await manager.deleteFolder('identity-copy');
        expect(manager.isExist(first.id, first.type), isFalse);
        expect(manager.isExist(second.id, second.type), isTrue);
        expect(manager.totalComics, 1);
        expect(manager.hasNewUpdate(second.id, second.type), isTrue);
      });
    },
    skip: !sqliteTestAvailable(),
  );

  test(
    'analyzed legacy favorites initialize indexes and survive restart',
    () async {
      final root = Directory.systemTemp.createTempSync('analyzed-favorites-');
      final checkpoint = appdata.captureImportCheckpoint();
      final manager = LocalFavoritesManager.independent();
      try {
        App.dataPath = root.path;
        App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
        appdata.settings['followUpdatesFolder'] = 'sqliteXnotes';
        appdata.settings['quickFavorite'] = 'legacy';
        final seed = sqlite3.open('${root.path}/local_favorite.db');
        late Map<String, Object?> internalBefore;
        try {
          seedAnalyzedLegacyFavorites(seed);
          // Rebuilding hierarchy metadata invalidates only its old statistics.
          internalBefore = sqliteInternalTableSnapshot(
            seed,
            excludeStatisticsFor: {'folder_order'},
          );
        } finally {
          seed.dispose();
        }

        for (var attempt = 0; attempt < 2; attempt++) {
          await manager.init();
          expect(manager.folderNames, ['sqliteXnotes', 'legacy']);
          expect(manager.counts, {'sqliteXnotes': 1, 'legacy': 1});
          expect(manager.totalComics, 2);
          expect(manager.isExist('legacy-id', ComicType.local), isTrue);
          expect(manager.isExist('modern-id', ComicType.local), isTrue);
          expect(manager.hasNewUpdate('modern-id', ComicType.local), isTrue);
          expect(manager.findLinked('legacy'), (
            'fixture-source',
            'remote-folder',
          ));
          expect(appdata.settings['followUpdatesFolder'], 'sqliteXnotes');
          expect(appdata.settings['quickFavorite'], 'legacy');
          final legacy = manager.getFolderComics('legacy').single;
          expect(legacy.name, 'Legacy favorite');
          expect(legacy.tags, ['tag', 'second']);
          expect(legacy.time, '2001-02-03 04:05:06');
          final asyncLegacy = (await manager.getFolderComicsAsync(
            'legacy',
          )).single;
          expect(asyncLegacy.toJson(), legacy.toJson());
          expect(asyncLegacy.time, legacy.time);
          expect(
            (await manager.getAllComicsAsync()).map((item) => item.id),
            unorderedEquals(['legacy-id', 'modern-id']),
          );
          expect(manager.search('Legacy').single.id, 'legacy-id');
          expect(
            manager.searchInFolder('sqliteXnotes', 'preserved').single.id,
            'modern-id',
          );
          final persisted = sqlite3.open(
            manager.databasePath,
            mode: OpenMode.readOnly,
          );
          try {
            expect(sqliteInternalTableSnapshot(persisted), internalBefore);
            expect(
              persisted.select('PRAGMA quick_check;').single['quick_check'],
              'ok',
            );
          } finally {
            persisted.dispose();
          }
          await manager.closeAndWait();
        }
      } finally {
        await manager.closeAndWait();
        manager.dispose();
        await appdata.restoreImportCheckpoint(checkpoint, persist: false);
        root.deleteSync(recursive: true);
      }
    },
    skip: !sqliteTestAvailable(),
  );
}
