import 'package:venera_next/foundation/directory_replacement.dart';
import 'pica_import.dart';
import 'app_data_archive.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/file_replacement.dart';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/foundation/file_system.dart';

Future<File> exportAppData([bool sync = true]) =>
    AppDataOperations.instance.run(() => _exportAppData(sync));

Future<File> _exportAppData(bool sync) async {
  final cacheFilePath = FilePath.join(
    App.cachePath,
    '${const Uuid().v4()}.venera',
  );
  final cacheFile = File(cacheFilePath);
  final dataPath = App.dataPath;
  await HistoryManager.cache?.waitForAsyncWrites();
  await appdata.saveData(false);
  final archiveData =
      jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
  if (sync) {
    final settings = archiveData['settings'] as Map<String, dynamic>;
    for (final field in appdata.splitField(
      settings['disableSyncFields'] as String,
    )) {
      settings.remove(field);
    }
  }
  final settingsJson = jsonEncode(archiveData);
  await AppDataArchive.create(
    dataPath: dataPath,
    cachePath: App.cachePath,
    destinationPath: cacheFilePath,
    settingsJson: settingsJson,
  );
  return cacheFile;
}

/// False means the archive was skipped by its embedded version check.
Future<bool> importAppData(File file, [bool checkVersion = false]) =>
    AppDataOperations.instance.run(() => _importAppData(file, checkVersion));

/// Sync cancellation is checked after queueing and immediately before replacement.
/// Once replacement starts, the existing commit/rollback path must finish.
Future<bool> importSyncAppData(
  File file, {
  required void Function() checkActive,
}) => AppDataOperations.instance.run(
  () => _importAppData(file, true, checkActive),
);

Future<bool> _importAppData(
  File file,
  bool checkVersion, [
  void Function()? checkActive,
]) async {
  checkActive?.call();
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
    await AppDataArchive.extract(file.path, cacheDirPath);
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
        return false;
      }
    }

    checkActive?.call();
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
      await _closeLocalFavoritesManagerForImport();
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
    return true;
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
    await cacheDir.deleteIgnoreError(recursive: true);
    if (success || rolledBack) {
      await backupDir.deleteIgnoreError(recursive: true);
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
  _ImportReplacement._({
    required this.targetPath,
    required this.backupPath,
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
      isDirectory: true,
    );
  }

  final String targetPath;
  final String backupPath;
  final bool isDirectory;

  FileReplacement? _fileReplacement;
  DirectoryReplacement? _directoryReplacement;

  void backup() {
    if (!isDirectory) {
      final replacement = FileReplacement(targetPath, backupPath);
      replacement.backup();
      _fileReplacement = replacement;
      return;
    }
    final replacement = DirectoryReplacement(targetPath, backupPath);
    replacement.backup();
    _directoryReplacement = replacement;
  }

  void restore() {
    if (isDirectory) {
      _directoryReplacement!.restore();
    } else {
      _fileReplacement!.restore();
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
    await _closeLocalFavoritesManagerForImport();
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

Future<void> _closeLocalFavoritesManagerForImport() async {
  await LocalFavoritesManager.cache?.closeAndWait();
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

Future<void> importPicaData(File file) => AppDataOperations.instance.run(
  () => importLegacyPicaArchive(file, cachePath: App.cachePath),
);
