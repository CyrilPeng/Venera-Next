import 'pica_import_storage.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/log.dart';
import 'app_data_archive.dart';
import 'legacy_pica_data.dart';

Future<void> importLegacyPicaArchive(
  File file, {
  required String cachePath,
}) async {
  var cacheDirPath = FilePath.join(cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await AppDataArchive.extract(file.path, cacheDirPath);
    final data = LegacyPicaData.read(
      cacheDirPath,
      sourceAvailable: (key) => ComicSource.find(key) != null,
    );
    if (data.folders.isEmpty &&
        data.links.isEmpty &&
        data.history.isEmpty &&
        data.images.isEmpty) {
      return;
    }
    final favorites = LocalFavoritesManager();
    final history = HistoryManager();
    await history.importStorage(
      (historyPath) {
        commitLegacyPicaData(
          data,
          favoritesPath: favorites.databasePath,
          historyPath: historyPath,
          appendFavorites: appdata.settings['newFavoriteAddTo'] == 'end',
          translateTags: (tags) => tags
              .map((tag) => (tag, tag.translateTagsToCN))
              .where((pair) => pair.$1 != pair.$2)
              .map((pair) => pair.$2)
              .join(','),
          invalidLink: (error, stack) => Log.error(error.toString(), stack),
        );
        favorites.refreshImportedFavorites(data.folders);
      },
      onCommitted: () {
        if (data.folders.isNotEmpty || data.links.isNotEmpty) {
          favorites.notifyImportedFavorites(data.folders.keys);
        }
        if (data.images.isNotEmpty) ImageFavoriteManager().notifyChanges();
      },
    );
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
