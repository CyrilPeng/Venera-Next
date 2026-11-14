import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'support/favorites_manager_fixture.dart';
import '../../support/sqlite_test_environment.dart';

void main() {
  test(
    'tracking folder switch does not relabel old cached identities',
    () async {
      final previous = appdata.settings['followUpdatesFolder'];
      try {
        await withFavoritesManager((manager) async {
          for (final folder in ['track-a', 'track-b']) {
            await manager.createFolder(folder);
            await manager.prepareTableForFollowUpdates(folder);
          }
          final old = managerFavorite('old');
          final first = managerFavorite('first');
          final second = managerFavorite('second');
          await manager.addComic('track-a', old);
          await manager.addComic('track-b', first);
          await manager.addComic('track-b', second);
          appdata.settings['followUpdatesFolder'] = 'track-a';
          manager.refreshUpdateIds();
          await manager.updateUpdateTime('track-a', old.id, old.type, 'v1');
          await manager.updateUpdateTime('track-b', first.id, first.type, 'v1');
          expect(manager.hasNewUpdate(old.id, old.type), isTrue);
          appdata.settings['followUpdatesFolder'] = 'track-b';
          expect(manager.hasNewUpdate(old.id, old.type), isFalse);
          await manager.updateUpdateTime(
            'track-b',
            second.id,
            second.type,
            'v1',
          );
          expect(manager.hasNewUpdate(old.id, old.type), isFalse);
          expect(manager.hasNewUpdate(first.id, first.type), isTrue);
          expect(manager.hasNewUpdate(second.id, second.type), isTrue);
          await manager.markAsRead(first.id, first.type, notify: false);
          expect(manager.hasNewUpdate(first.id, first.type), isFalse);
          expect(manager.hasNewUpdate(second.id, second.type), isTrue);
        });
      } finally {
        appdata.settings['followUpdatesFolder'] = previous;
      }
    },
  );

  test(
    'init creates tracking folder and selects it for follow updates',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      appdata.settings['followUpdatesFolder'] = 'obsolete-folder';
      appdata.settings['quickFavorite'] = 'obsolete-folder';

      final manager = ownedFavoritesManager();
      await manager.init();

      expect(
        manager.folderNames,
        contains(LocalFavoritesManager.trackingFolderName),
      );
      expect(
        appdata.settings['followUpdatesFolder'],
        LocalFavoritesManager.trackingFolderName,
      );
      expect(
        appdata.settings['quickFavorite'],
        LocalFavoritesManager.trackingFolderName,
      );

      final item = managerFavorite('tracked');
      await manager.addComic(
        LocalFavoritesManager.trackingFolderName,
        item,
        null,
        '2026-07-02',
      );
      final tracked = manager.getComicsWithUpdatesInfo(
        LocalFavoritesManager.trackingFolderName,
      );

      expect(tracked, hasLength(1));
      expect(tracked.single.updateTime, '2026-07-02');
      expect(tracked.single.hasNewUpdate, isFalse);
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'init preserves valid quick favorite folder without creating tracking',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      appdata.settings['followUpdatesFolder'] = null;
      appdata.settings['quickFavorite'] = 'custom';

      final seed = sqlite3.open('${dataDir.path}/local_favorite.db');
      try {
        seed.execute("""
          create table folder_order (
            folder_name text primary key,
            order_value int
          );
        """);
        seed.execute("""
          create table folder_sync (
            folder_name text primary key,
            source_key text,
            source_folder text
          );
        """);
        seed.execute("""
          create table custom(
            id text,
            name TEXT,
            author TEXT,
            type int,
            tags TEXT,
            cover_path TEXT,
            time TEXT,
            display_order int,
            translated_tags TEXT,
            primary key (id, type)
          );
        """);
      } finally {
        seed.dispose();
      }

      final manager = ownedFavoritesManager();
      await manager.init();

      expect(appdata.settings['followUpdatesFolder'], isNull);
      expect(appdata.settings['quickFavorite'], 'custom');
      expect(
        manager.folderNames,
        isNot(contains(LocalFavoritesManager.trackingFolderName)),
      );
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'init preserves a custom tracking folder after restart',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      addTearDown(() async {
        await appdata.saveData(false);
        if (LocalFavoritesManager.cache != null) {}

        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      final firstManager = ownedFavoritesManager();
      await firstManager.init();
      await firstManager.createFolder('B');
      appdata.settings['followUpdatesFolder'] = 'B';
      await firstManager.prepareTableForFollowUpdates('B');
      await firstManager.deleteFolder(LocalFavoritesManager.trackingFolderName);
      firstManager.close();

      final secondManager = ownedFavoritesManager();
      await secondManager.init();

      expect(secondManager.folderNames, ['B']);
      expect(appdata.settings['followUpdatesFolder'], 'B');
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'tracks cached update status for the follow updates folder',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      final previousFollowUpdatesFolder =
          appdata.settings['followUpdatesFolder'];
      addTearDown(() async {
        appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;

      final manager = ownedFavoritesManager();
      await manager.init();
      const folder = LocalFavoritesManager.trackingFolderName;
      final item = managerFavorite('updated-comic');

      await manager.addComic(folder, item, null, '2026-07-01');
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);

      await manager.updateUpdateTime(folder, item.id, item.type, '2026-07-02');
      expect(manager.hasNewUpdate(item.id, item.type), isTrue);

      await manager.markAsRead(item.id, item.type, notify: false);
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'follow updates preview returns all comics in the tracking folder',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final updated = managerFavorite('updated-preview');
        final unchanged = managerFavorite('unchanged-preview');

        await manager.addComic(folder, updated, null, '2026-07-01');
        await manager.addComic(folder, unchanged, null, '2026-07-01');
        await manager.updateUpdateTime(
          folder,
          updated.id,
          updated.type,
          '2026-07-02',
        );

        final preview = getFollowUpdatesPreviewComics(folder, manager: manager);

        expect(
          preview.map((comic) => comic.id),
          unorderedEquals([updated.id, unchanged.id]),
        );
        expect(preview.where((comic) => comic.hasNewUpdate), hasLength(1));
        expect(manager.countUpdates(folder), 1);
      });
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'delete and move operations clear cached follow update status',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        await manager.createFolder('target');

        Future<void> addUpdated(FavoriteItem item) async {
          await manager.addComic(folder, item, null, '2026-07-01');
          await manager.updateUpdateTime(
            folder,
            item.id,
            item.type,
            '2026-07-02',
          );
          expect(manager.hasNewUpdate(item.id, item.type), isTrue);
        }

        final deleted = managerFavorite('delete-one');
        await addUpdated(deleted);
        await manager.deleteComicWithId(folder, deleted.id, deleted.type);
        expect(manager.hasNewUpdate(deleted.id, deleted.type), isFalse);

        final batchDeleted = managerFavorite('delete-batch');
        await addUpdated(batchDeleted);
        await manager.batchDeleteComics(folder, [batchDeleted]);
        expect(
          manager.hasNewUpdate(batchDeleted.id, batchDeleted.type),
          isFalse,
        );

        final deletedEverywhere = managerFavorite('delete-everywhere');
        await addUpdated(deletedEverywhere);
        deleteFavoritesExternally(manager, [
          ComicID(deletedEverywhere.type, deletedEverywhere.id),
        ]);
        expect(
          manager.hasNewUpdate(deletedEverywhere.id, deletedEverywhere.type),
          isFalse,
        );

        final moved = managerFavorite('move-one');
        await addUpdated(moved);
        await manager.moveFavorite(folder, 'target', moved.id, moved.type);
        expect(manager.hasNewUpdate(moved.id, moved.type), isFalse);

        final batchMoved = managerFavorite('move-batch');
        await addUpdated(batchMoved);
        await manager.batchMoveFavorites(folder, 'target', [batchMoved]);
        expect(manager.hasNewUpdate(batchMoved.id, batchMoved.type), isFalse);
      });
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );

  test(
    'folder delete and rename refresh cached follow update status',
    () async {
      await withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final renamed = managerFavorite('rename-follow');

        await manager.addComic(folder, renamed, null, '2026-07-01');
        await manager.updateUpdateTime(
          folder,
          renamed.id,
          renamed.type,
          '2026-07-02',
        );
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        await manager.rename(folder, 'renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], 'renamed-follow');
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        await manager.deleteFolder('renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], isNull);
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isFalse);
      });
    },
    skip: sqliteTestAvailable()
        ? false
        : 'sqlite3 native library is unavailable',
  );
}
