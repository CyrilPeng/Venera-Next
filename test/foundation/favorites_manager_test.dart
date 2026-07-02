import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';

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
