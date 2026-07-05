import 'dart:convert';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:zip_flutter/zip_flutter.dart';

Future<File> exportAppData([bool sync = true]) async {
  var time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var cacheFilePath = FilePath.join(App.cachePath, '$time.venera');
  var cacheFile = File(cacheFilePath);
  var dataPath = App.dataPath;
  if (await cacheFile.exists()) {
    await cacheFile.delete();
  }
  await Isolate.run(() {
    var zipFile = ZipFile.open(cacheFilePath);
    var historyFile = FilePath.join(dataPath, "history.db");
    var localFavoriteFile = FilePath.join(dataPath, "local_favorite.db");
    var appdata = FilePath.join(
      dataPath,
      sync ? "syncdata.json" : "appdata.json",
    );
    var cookies = FilePath.join(dataPath, "cookie.db");
    zipFile.addFile("history.db", historyFile);
    zipFile.addFile("local_favorite.db", localFavoriteFile);
    zipFile.addFile("appdata.json", appdata);
    zipFile.addFile("cookie.db", cookies);
    for (var file in Directory(
      FilePath.join(dataPath, "comic_source"),
    ).listSync()) {
      if (file is File) {
        zipFile.addFile("comic_source/${file.name}", file.path);
      }
    }
    zipFile.close();
  });
  return cacheFile;
}

Future<void> importAppData(File file, [bool checkVersion = false]) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  var backupDir = Directory(
    FilePath.join(
      App.dataPath,
      '.import_backup_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  var replacements = <_ImportReplacement>[];
  var reloadHistory = false;
  var reloadLocalFavorites = false;
  var reloadCookies = false;
  var reloadComicSources = false;
  var success = false;
  var rolledBack = false;
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var historyFile = cacheDir.joinFile("history.db");
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    var appdataFile = cacheDir.joinFile("appdata.json");
    var cookieFile = cacheDir.joinFile("cookie.db");

    Map<String, dynamic>? importedAppdata;
    if (appdataFile.existsSync()) {
      importedAppdata = _decodeImportAppdata(await appdataFile.readAsString());
    }
    if (checkVersion && importedAppdata != null) {
      var importedSettings = importedAppdata["settings"];
      var version = importedSettings is Map
          ? importedSettings["dataVersion"]
          : null;
      if (version is int && version <= appdata.settings["dataVersion"]) {
        return;
      }
    }

    backupDir.createSync();

    if (await historyFile.exists()) {
      await _closeHistoryManagerForImport();
      reloadHistory = true;
      await _replaceFileForImport(
        source: historyFile,
        targetPath: FilePath.join(App.dataPath, "history.db"),
        backupDir: backupDir,
        backupName: "history.db",
        replacements: replacements,
      );
    }
    if (await localFavoriteFile.exists()) {
      _closeLocalFavoritesManagerForImport();
      reloadLocalFavorites = true;
      await _replaceFileForImport(
        source: localFavoriteFile,
        targetPath: FilePath.join(App.dataPath, "local_favorite.db"),
        backupDir: backupDir,
        backupName: "local_favorite.db",
        replacements: replacements,
      );
    }
    if (await cookieFile.exists()) {
      _closeCookieJarForImport();
      reloadCookies = true;
      await _replaceFileForImport(
        source: cookieFile,
        targetPath: FilePath.join(App.dataPath, "cookie.db"),
        backupDir: backupDir,
        backupName: "cookie.db",
        replacements: replacements,
      );
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    if (Directory(comicSourceDir).existsSync()) {
      reloadComicSources = true;
      await _replaceDirectoryForImport(
        source: Directory(comicSourceDir),
        targetPath: FilePath.join(App.dataPath, "comic_source"),
        backupDir: backupDir,
        backupName: "comic_source",
        replacements: replacements,
      );
    }

    if (reloadHistory) {
      await HistoryManager().init();
    }
    if (reloadLocalFavorites) {
      await LocalFavoritesManager().init();
    }
    if (reloadCookies) {
      _openCookieJarForImport();
    }
    if (reloadComicSources) {
      await ComicSourceManager().reload();
    }

    if (importedAppdata != null) {
      appdata.syncData(importedAppdata);
    }
    success = true;
  } catch (error, stackTrace) {
    try {
      await _rollbackImport(
        replacements: replacements,
        reloadHistory: reloadHistory,
        reloadLocalFavorites: reloadLocalFavorites,
        reloadCookies: reloadCookies,
        reloadComicSources: reloadComicSources,
      );
      rolledBack = true;
    } catch (rollbackError, rollbackStackTrace) {
      Log.error(
        "Import Data",
        "Failed to rollback app data import: $rollbackError",
        rollbackStackTrace,
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
    if (success || rolledBack) {
      backupDir.deleteIgnoreError(recursive: true);
    }
  }
}

Map<String, dynamic> _decodeImportAppdata(String content) {
  var data = jsonDecode(content);
  if (data is! Map) {
    throw const FormatException("Invalid appdata.json root");
  }
  var result = Map<String, dynamic>.from(data);
  var settings = result["settings"];
  if (settings != null) {
    if (settings is! Map) {
      throw const FormatException("Invalid appdata.json settings");
    }
    result["settings"] = Map<String, dynamic>.from(settings);
  }
  var searchHistory = result["searchHistory"];
  if (searchHistory != null) {
    if (searchHistory is! List ||
        searchHistory.any((element) => element is! String)) {
      throw const FormatException("Invalid appdata.json searchHistory");
    }
    result["searchHistory"] = List<String>.from(searchHistory);
  }
  return result;
}

class _ImportReplacement {
  const _ImportReplacement._({
    required this.targetPath,
    required this.backupPath,
    required this.wasExisting,
    required this.isDirectory,
  });

  factory _ImportReplacement.file(
    String targetPath,
    Directory backupDir,
    String backupName,
  ) {
    return _ImportReplacement._(
      targetPath: targetPath,
      backupPath: FilePath.join(backupDir.path, backupName),
      wasExisting: File(targetPath).existsSync(),
      isDirectory: false,
    );
  }

  factory _ImportReplacement.directory(
    String targetPath,
    Directory backupDir,
    String backupName,
  ) {
    return _ImportReplacement._(
      targetPath: targetPath,
      backupPath: FilePath.join(backupDir.path, backupName),
      wasExisting: Directory(targetPath).existsSync(),
      isDirectory: true,
    );
  }

  final String targetPath;
  final String backupPath;
  final bool wasExisting;
  final bool isDirectory;

  void backup() {
    if (!wasExisting) return;
    if (isDirectory) {
      Directory(targetPath).renameSync(backupPath);
    } else {
      File(targetPath).renameSync(backupPath);
    }
  }

  void restore() {
    if (isDirectory) {
      Directory(targetPath).deleteIfExistsSync(recursive: true);
      if (wasExisting && Directory(backupPath).existsSync()) {
        Directory(backupPath).renameSync(targetPath);
      }
    } else {
      File(targetPath).deleteIfExistsSync();
      if (wasExisting && File(backupPath).existsSync()) {
        File(backupPath).renameSync(targetPath);
      }
    }
  }
}

Future<void> _replaceFileForImport({
  required File source,
  required String targetPath,
  required Directory backupDir,
  required String backupName,
  required List<_ImportReplacement> replacements,
}) async {
  var replacement = _ImportReplacement.file(targetPath, backupDir, backupName);
  replacement.backup();
  replacements.add(replacement);
  await source.copy(targetPath);
}

Future<void> _replaceDirectoryForImport({
  required Directory source,
  required String targetPath,
  required Directory backupDir,
  required String backupName,
  required List<_ImportReplacement> replacements,
}) async {
  var replacement = _ImportReplacement.directory(
    targetPath,
    backupDir,
    backupName,
  );
  replacement.backup();
  replacements.add(replacement);
  await copyDirectory(source, Directory(targetPath));
}

Future<void> _rollbackImport({
  required List<_ImportReplacement> replacements,
  required bool reloadHistory,
  required bool reloadLocalFavorites,
  required bool reloadCookies,
  required bool reloadComicSources,
}) async {
  if (reloadHistory) {
    await _closeHistoryManagerForImport();
  }
  if (reloadLocalFavorites) {
    _closeLocalFavoritesManagerForImport();
  }
  if (reloadCookies) {
    _closeCookieJarForImport();
  }

  for (var replacement in replacements.reversed) {
    replacement.restore();
  }

  if (reloadHistory) {
    await HistoryManager().init();
  }
  if (reloadLocalFavorites) {
    await LocalFavoritesManager().init();
  }
  if (reloadCookies) {
    _openCookieJarForImport();
  }
  if (reloadComicSources) {
    await ComicSourceManager().reload();
  }
}

Future<void> _closeHistoryManagerForImport() async {
  try {
    final manager = HistoryManager.cache;
    if (manager == null) {
      return;
    }
    await manager.waitForAsyncWrites();
    manager.close();
  } catch (_) {
    // ignore partially initialized managers
  }
}

void _closeLocalFavoritesManagerForImport() {
  try {
    LocalFavoritesManager.cache?.close();
  } catch (_) {
    // ignore partially initialized managers
  }
}

void _closeCookieJarForImport() {
  try {
    SingleInstanceCookieJar.instance?.dispose();
  } catch (_) {
    // ignore partially initialized cookie jars
  } finally {
    SingleInstanceCookieJar.instance = null;
  }
}

void _openCookieJarForImport() {
  SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
    FilePath.join(App.dataPath, "cookie.db"),
  );
}

Future<void> importPicaData(File file) async {
  var cacheDirPath = FilePath.join(App.cachePath, 'temp_data');
  var cacheDir = Directory(cacheDirPath);
  if (cacheDir.existsSync()) {
    cacheDir.deleteSync(recursive: true);
  }
  cacheDir.createSync();
  try {
    await Isolate.run(() {
      ZipFile.openAndExtract(file.path, cacheDirPath);
    });
    var localFavoriteFile = cacheDir.joinFile("local_favorite.db");
    if (localFavoriteFile.existsSync()) {
      var db = sqlite3.open(localFavoriteFile.path);
      try {
        var folderNames = db
            .select("SELECT name FROM sqlite_master WHERE type='table';")
            .map((e) => e["name"] as String)
            .toList();
        folderNames.removeWhere(
          (e) => e == "folder_order" || e == "folder_sync",
        );
        for (var folderSyncValue in db.select("SELECT * FROM folder_sync;")) {
          var folderName = folderSyncValue["folder_name"];
          String sourceKey = folderSyncValue["key"];
          sourceKey = sourceKey.toLowerCase() == "htmanga"
              ? "wnacg"
              : sourceKey;
          // 有值就跳过
          if (LocalFavoritesManager().findLinked(folderName).$1 != null) {
            continue;
          }
          try {
            LocalFavoritesManager().linkFolderToNetwork(
              folderName,
              sourceKey,
              jsonDecode(folderSyncValue["sync_data"])["folderId"],
            );
          } catch (e, stack) {
            Log.error(e.toString(), stack);
          }
        }
        for (var folderName in folderNames) {
          if (!LocalFavoritesManager().existsFolder(folderName)) {
            LocalFavoritesManager().createFolder(folderName);
          }
          for (var comic in db.select("SELECT * FROM \"$folderName\";")) {
            LocalFavoritesManager().addComic(
              folderName,
              FavoriteItem(
                id: comic['target'],
                name: comic['name'],
                coverPath: comic['cover_path'],
                author: comic['author'],
                type: ComicType(switch (comic['type']) {
                  0 => 'picacg'.hashCode,
                  1 => 'ehentai'.hashCode,
                  2 => 'jm'.hashCode,
                  3 => 'hitomi'.hashCode,
                  4 => 'wnacg'.hashCode,
                  6 => 'nhentai'.hashCode,
                  _ => comic['type'],
                }),
                tags: comic['tags'].split(','),
              ),
            );
          }
        }
      } catch (e) {
        Log.error("Import Data", "Failed to import local favorite: $e");
      } finally {
        db.dispose();
      }
    }
    var historyFile = cacheDir.joinFile("history.db");
    if (historyFile.existsSync()) {
      var db = sqlite3.open(historyFile.path);
      try {
        for (var comic in db.select("SELECT * FROM history;")) {
          HistoryManager().addHistory(
            History.fromMap({
              "type": switch (comic['type']) {
                0 => 'picacg'.hashCode,
                1 => 'ehentai'.hashCode,
                2 => 'jm'.hashCode,
                3 => 'hitomi'.hashCode,
                4 => 'wnacg'.hashCode,
                5 => 'nhentai'.hashCode,
                _ => comic['type'],
              },
              "id": comic['target'],
              "max_page": comic["max_page"],
              "ep": comic["ep"],
              "page": comic["page"],
              "time": comic["time"],
              "title": comic["title"],
              "subtitle": comic["subtitle"],
              "cover": comic["cover"],
              "readEpisode": [comic["ep"]],
            }),
          );
        }
        List<ImageFavoritesComic> imageFavoritesComicList =
            ImageFavoriteManager().comics;
        for (var comic in db.select("SELECT * FROM image_favorites;")) {
          String sourceKey = comic["id"].split("-")[0];
          // 换名字了, 绅士漫画
          if (sourceKey.toLowerCase() == "htmanga") {
            sourceKey = "wnacg";
          }
          if (ComicSource.find(sourceKey) == null) {
            continue;
          }
          String id = comic["id"].split("-")[1];
          int page = comic["page"];
          // 章节和page是从1开始的, pica 可能有从 0 开始的, 得转一下
          int ep = comic["ep"] == 0 ? 1 : comic["ep"];
          String title = comic["title"];
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
      } finally {
        db.dispose();
      }
    }
  } finally {
    cacheDir.deleteIgnoreError(recursive: true);
  }
}
