import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/extensions.dart';
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
    if (data.folders.isNotEmpty || data.links.isNotEmpty) {
      try {
        for (final link in data.links) {
          if (LocalFavoritesManager().findLinked(link.folder).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(
              link.folder,
              link.sourceKey,
              link.networkFolder,
            );
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (final folderName in data.folders.keys) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (final comic in data.folders[folderName]!) {
            LocalFavoritesManager().addComic(folderName, comic);
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      }
    }
    if (data.history.isNotEmpty || data.images.isNotEmpty) {
      try {
        for (final comic in data.history) {
          await HistoryManager().importHistory(comic);
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (final comic in data.images) {
          final sourceKey = comic.sourceKey;
          final id = comic.id;
          final page = comic.page;
          final ep = comic.ep;
          final title = comic.title;
          String epName = "";
          ImageFavoritesComic? tempComic = imageFavoritesComicList
              .firstWhereOrNull((e) => e.id == id && e.sourceKey == sourceKey);
          ImageFavorite curImageFavorite = ImageFavorite(
            page,
            "",
            null,
            "",
            id,
            ep,
            sourceKey,
            epName,
          );
          if (tempComic == null) {
            tempComic = ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              [],
              [],
              DateTime.now(),
              "",
              {},
              "",
              1,
            );
            tempComic.imageFavoritesEp = [
              ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
            ];
            imageFavoritesComicList.add(tempComic);
          } else {
            ImageFavoritesEp? tempEp = tempComic.imageFavoritesEp
                .firstWhereOrNull((e) => e.ep == ep);
            if (tempEp == null) {
              tempComic.imageFavoritesEp.add(
                ImageFavoritesEp("", ep, [curImageFavorite], epName, 1),
              );
            } else {
              // 如果已经有这个page了, 就不添加了
              if (tempEp.imageFavorites.firstWhereOrNull(
                    (e) => e.page == page,
                  ) ==
                  null) {
                tempEp.imageFavorites.add(curImageFavorite);
              }
            }
          }
        }
        for (var temp in imageFavoritesComicList) {
          ImageFavoriteManager().addOrUpdateOrDelete(
            temp,
            temp == imageFavoritesComicList.last,
          );
        }
      } catch (e, stack) {
        Log.error("Import Data", "Failed to import history: $e", stack);
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
