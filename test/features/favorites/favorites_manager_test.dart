import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';

FavoriteItem _favorite(String id) {
  return FavoriteItem(
    id: id,
    name: 'Comic $id',
    coverPath: 'cover-$id.jpg',
    author: 'Author',
    type: ComicType.local,
    tags: const ['tag'],
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _withFavoritesManager(
  Future<void> Function(LocalFavoritesManager manager) run,
) async {
  final dataDir = Directory.systemTemp.createTempSync('venera-favorites-data-');
  final cacheDir = Directory.systemTemp.createTempSync(
    'venera-favorites-cache-',
  );
  final previousFollowUpdatesFolder = appdata.settings['followUpdatesFolder'];
  final previousQuickFavorite = appdata.settings['quickFavorite'];
  LocalFavoritesManager? manager;
  try {
    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
    LocalFavoritesManager.cache = null;

    manager = LocalFavoritesManager();
    await manager.init();
    await run(manager);
    await appdata.saveData(false);
  } finally {
    if (manager != null) {
      await manager.debugWaitForHashedIdsRefresh();
      try {
        manager.close();
      } catch (_) {
        // ignore cleanup failures in partially initialized tests
      }
    }
    LocalFavoritesManager.cache = null;
    appdata.settings['followUpdatesFolder'] = previousFollowUpdatesFolder;
    appdata.settings['quickFavorite'] = previousQuickFavorite;
    if (dataDir.existsSync()) {
      dataDir.deleteSync(recursive: true);
    }
    if (cacheDir.existsSync()) {
      cacheDir.deleteSync(recursive: true);
    }
  }
}

void main() {
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
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
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
      LocalFavoritesManager.cache = null;
      appdata.settings['followUpdatesFolder'] = 'obsolete-folder';
      appdata.settings['quickFavorite'] = 'obsolete-folder';

      final manager = LocalFavoritesManager();
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

      final item = _favorite('tracked');
      manager.addComic(
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
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init preserves valid quick favorite folder',
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
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
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
      LocalFavoritesManager.cache = null;
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

      final manager = LocalFavoritesManager();
      await manager.init();

      expect(
        appdata.settings['followUpdatesFolder'],
        LocalFavoritesManager.trackingFolderName,
      );
      expect(appdata.settings['quickFavorite'], 'custom');
      expect(
        manager.folderNames,
        contains(LocalFavoritesManager.trackingFolderName),
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
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
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
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
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      const folder = LocalFavoritesManager.trackingFolderName;
      final item = _favorite('updated-comic');

      manager.addComic(folder, item, null, '2026-07-01');
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);

      manager.updateUpdateTime(folder, item.id, item.type, '2026-07-02');
      expect(manager.hasNewUpdate(item.id, item.type), isTrue);

      manager.markAsRead(item.id, item.type, notify: false);
      expect(manager.hasNewUpdate(item.id, item.type), isFalse);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'follow updates preview returns all comics in the tracking folder',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final updated = _favorite('updated-preview');
        final unchanged = _favorite('unchanged-preview');

        manager.addComic(folder, updated, null, '2026-07-01');
        manager.addComic(folder, unchanged, null, '2026-07-01');
        manager.updateUpdateTime(
          folder,
          updated.id,
          updated.type,
          '2026-07-02',
        );

        final preview = getFollowUpdatesPreviewComics(folder);

        expect(
          preview.map((comic) => comic.id),
          unorderedEquals([updated.id, unchanged.id]),
        );
        expect(preview.where((comic) => comic.hasNewUpdate), hasLength(1));
        expect(manager.countUpdates(folder), 1);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'delete and move operations clear cached follow update status',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        manager.createFolder('target');

        void addUpdated(FavoriteItem item) {
          manager.addComic(folder, item, null, '2026-07-01');
          manager.updateUpdateTime(folder, item.id, item.type, '2026-07-02');
          expect(manager.hasNewUpdate(item.id, item.type), isTrue);
        }

        final deleted = _favorite('delete-one');
        addUpdated(deleted);
        manager.deleteComicWithId(folder, deleted.id, deleted.type);
        expect(manager.hasNewUpdate(deleted.id, deleted.type), isFalse);

        final batchDeleted = _favorite('delete-batch');
        addUpdated(batchDeleted);
        manager.batchDeleteComics(folder, [batchDeleted]);
        expect(
          manager.hasNewUpdate(batchDeleted.id, batchDeleted.type),
          isFalse,
        );

        final deletedEverywhere = _favorite('delete-everywhere');
        addUpdated(deletedEverywhere);
        manager.batchDeleteComicsInAllFolders([
          ComicID(deletedEverywhere.type, deletedEverywhere.id),
        ]);
        expect(
          manager.hasNewUpdate(deletedEverywhere.id, deletedEverywhere.type),
          isFalse,
        );

        final moved = _favorite('move-one');
        addUpdated(moved);
        manager.moveFavorite(folder, 'target', moved.id, moved.type);
        expect(manager.hasNewUpdate(moved.id, moved.type), isFalse);

        final batchMoved = _favorite('move-batch');
        addUpdated(batchMoved);
        manager.batchMoveFavorites(folder, 'target', [batchMoved]);
        expect(manager.hasNewUpdate(batchMoved.id, batchMoved.type), isFalse);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'folder delete and rename refresh cached follow update status',
    () async {
      await _withFavoritesManager((manager) async {
        const folder = LocalFavoritesManager.trackingFolderName;
        final renamed = _favorite('rename-follow');

        manager.addComic(folder, renamed, null, '2026-07-01');
        manager.updateUpdateTime(
          folder,
          renamed.id,
          renamed.type,
          '2026-07-02',
        );
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        manager.rename(folder, 'renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], 'renamed-follow');
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isTrue);

        manager.deleteFolder('renamed-follow');

        expect(appdata.settings['followUpdatesFolder'], isNull);
        expect(manager.hasNewUpdate(renamed.id, renamed.type), isFalse);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'empty batch favorite operations do not notify listeners',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('source');
      manager.createFolder('target');

      var notifyCount = 0;
      void listener() {
        notifyCount++;
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));

      manager.batchMoveFavorites('source', 'target', <FavoriteItem>[]);
      manager.batchCopyFavorites('source', 'target', <FavoriteItem>[]);
      manager.batchDeleteComics('source', <FavoriteItem>[]);
      manager.batchDeleteComicsInAllFolders([]);

      expect(notifyCount, 0);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 0);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'batchMoveFavorites notifies after counts are updated',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-favorites-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-favorites-cache-',
      );
      addTearDown(() async {
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        try {
          LocalFavoritesManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        LocalFavoritesManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalFavoritesManager.cache = null;

      final manager = LocalFavoritesManager();
      await manager.init();
      manager.createFolder('source');
      manager.createFolder('target');
      final first = _favorite('first');
      final second = _favorite('second');
      manager.addComic('source', first);
      manager.addComic('source', second);

      final observedCounts = <(int source, int target)>[];
      var isBatching = false;
      void listener() {
        if (isBatching) {
          observedCounts.add((
            manager.folderComics('source'),
            manager.folderComics('target'),
          ));
        }
      }

      manager.addListener(listener);
      addTearDown(() => manager.removeListener(listener));

      isBatching = true;
      manager.batchMoveFavorites('source', 'target', [first, second]);
      isBatching = false;

      expect(observedCounts, [(0, 2)]);
      expect(manager.count('source'), 0);
      expect(manager.count('target'), 2);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
