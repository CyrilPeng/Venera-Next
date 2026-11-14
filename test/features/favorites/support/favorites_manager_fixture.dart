import 'package:venera_next/features/favorites/favorites_repository.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';

FavoriteItem managerFavorite(String id) {
  return FavoriteItem(
    id: id,
    name: 'Comic $id',
    coverPath: 'cover-$id.jpg',
    author: 'Author',
    type: ComicType.local,
    tags: const ['tag'],
  );
}

// Exercise publication of a committed external deletion independently of the
// local/history coordinator, including no-op and failure-before-publication.
void deleteFavoritesExternally(
  LocalFavoritesManager manager,
  List<ComicID> comics,
) {
  final db = sqlite3.open(manager.databasePath);
  try {
    final removed = FavoritesRepository(db).deleteComics(
      manager.folderNames,
      comics.map((comic) => (comic.id, comic.type.value)),
    );
    manager.refreshDeletedFavorites(removed);
  } finally {
    db.dispose();
  }
}

Future<void> withFavoritesManager(
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

    manager = LocalFavoritesManager.independent();
    await manager.init();
    await run(manager);
    await appdata.saveData(false);
  } finally {
    if (manager != null) {
      await manager.debugWaitForHashedIdsRefresh();
      try {
        await manager.closeAndWait();
      } catch (_) {
        // ignore cleanup failures in partially initialized tests
      }
    }

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

LocalFavoritesManager ownedFavoritesManager() {
  final manager = LocalFavoritesManager.independent();
  addTearDown(() async {
    await manager.debugWaitForHashedIdsRefresh();
    await manager.closeAndWait();
    manager.dispose();
  });
  return manager;
}
