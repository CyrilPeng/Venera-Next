import 'app_data_import_journal.dart';
import 'pica_import.dart';
import 'app_data_archive.dart';
import 'data_sync_commit.dart';
import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/foundation/file_system.dart';

Future<File> exportAppData([bool sync = true]) =>
    AppDataOperations.instance.run(() => _exportAppData(sync));

/// The upload journal owns this destination and its staging directory before
/// export starts, so interrupted work can be cleaned without scanning caches.
Future<void> exportSyncAppData({
  required bool excludeFields,
  required File destination,
}) => AppDataOperations.instance.run(() async {
  await _exportAppData(excludeFields, destination: destination);
});

Future<File> _exportAppData(bool sync, {File? destination}) async {
  final cacheFilePath =
      destination?.path ??
      FilePath.join(App.cachePath, '${const Uuid().v4()}.venera');
  final stagingDirectoryPath = destination == null
      ? null
      : FilePath.join(destination.parent.path, 'export-staging');
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
    stagingDirectoryPath: stagingDirectoryPath,
  );
  return cacheFile;
}

/// An older archive is [DataSyncCommitState.notApplied]. Failures after the
/// replacement boundary carry explicit commit or recovery evidence.
Future<DataSyncCommitState> importAppData(
  File file, [
  bool checkVersion = false,
]) => AppDataOperations.instance.run(() => _importAppData(file, checkVersion));

/// Sync cancellation is checked after queueing and immediately before replacement.
/// Once replacement starts, the existing commit/rollback path must finish.
/// [publishImported] wraps only notifications originating from the snapshot or
/// its rollback, including a repository's deferred cache publication.
Future<DataSyncCommitState> importSyncAppData(
  File file, {
  required void Function() checkActive,
  void Function(void Function())? publishImported,
  String? syncOperationId,
}) => AppDataOperations.instance.run(
  () => _importAppData(
    file,
    true,
    checkActive: checkActive,
    publishImported: publishImported,
    syncOperationId: syncOperationId,
  ),
);

Future<DataSyncCommitState> _importAppData(
  File file,
  bool checkVersion, {
  void Function()? checkActive,
  void Function(void Function())? publishImported,
  String? syncOperationId,
}) async {
  checkActive?.call();
  final cacheDir = await Directory(
    App.cachePath,
  ).createTemp('app-data-import-');
  final cacheDirPath = cacheDir.path;
  AppDataImportJournal? journal;
  AppDataImportTransaction? transaction;
  AppdataImportCheckpoint? checkpoint;
  var reloadHistory = false;
  var reloadLocalFavorites = false;
  var reloadCookies = false;
  var reloadComicSources = false;
  var mutationStarted = false;
  var state = DataSyncCommitState.notApplied;
  final failures = <DataSyncDiagnostic>[];
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
        return DataSyncCommitState.notApplied;
      }
    }

    checkActive?.call();
    journal = AppDataImportJournal.open(App.dataPath);
    journal.checkReadyForImport();
    // Close every participating database before creating immutable backups.
    // A failed close leaves its live file untouched and the other hosts reopen.
    await appdata.saveData(false);
    checkActive?.call();
    checkpoint = appdata.captureImportCheckpoint();
    if (await historyFile.exists()) {
      reloadHistory = true;
      await _closeHistoryManagerForImport();
    }
    if (await localFavoriteFile.exists()) {
      reloadLocalFavorites = true;
      await _closeLocalFavoritesManagerForImport();
    }
    if (await cookieFile.exists()) {
      reloadCookies = true;
      _closeCookieJarForImport();
    }
    var comicSourceDir = FilePath.join(cacheDirPath, "comic_source");
    final hasComicSources = Directory(comicSourceDir).existsSync();
    checkActive?.call();
    transaction = await journal.prepare(
      resources: {
        if (reloadHistory) 'history.db',
        if (reloadLocalFavorites) 'local_favorite.db',
        if (reloadCookies) 'cookie.db',
        if (hasComicSources) 'comic_source',
      },
      syncOperationId: syncOperationId,
    );
    checkActive?.call();
    mutationStarted = true;
    // Repository reopen and source initialization can save settings as well.
    // Register all fallback channels before permitting any of those effects.
    for (final name in const [
      'appdata.json',
      'appdata.json.bak',
      'appdata.json.tmp',
      'syncdata.json',
      'syncdata.json.bak',
      'syncdata.json.tmp',
    ]) {
      await transaction.markChanging(name);
    }
    if (reloadHistory) {
      await transaction.replaceFile('history.db', historyFile);
    }
    if (reloadLocalFavorites) {
      await transaction.replaceFile('local_favorite.db', localFavoriteFile);
    }
    if (reloadCookies) {
      await transaction.replaceFile('cookie.db', cookieFile);
    }
    if (hasComicSources) {
      reloadComicSources = true;
      await transaction.replaceDirectory(
        'comic_source',
        Directory(comicSourceDir),
      );
    }

    if (reloadHistory) {
      await HistoryManager().init();
    }
    if (reloadLocalFavorites) {
      await LocalFavoritesManager().init(publishChange: publishImported);
    }
    if (reloadCookies) {
      _openCookieJarForImport();
    }
    if (reloadComicSources) {
      await ComicSourceManager().reload(publishChange: publishImported);
    }

    if (importedAppdata != null) {
      await appdata.syncData(importedAppdata);
    } else {
      // Reopening a repository may have repaired metadata settings.
      await appdata.saveData(false);
    }
    await transaction.markApplied(DateTime.now().millisecondsSinceEpoch);
    state = DataSyncCommitState.applied;
  } catch (error, stackTrace) {
    if (error is DataSyncFailure) state = error.commitState;
    failures.add((stage: 'import app data', error: error, stack: stackTrace));
    // A durable applied marker is authoritative even if a later callback fails.
    var outcomeReadable = true;
    if (transaction != null) {
      state = DataSyncCommitState.recoveryRequired;
      try {
        state = transaction.state;
      } catch (error, stack) {
        outcomeReadable = false;
        failures.add((
          stage: 'read import outcome',
          error: error,
          stack: stack,
        ));
      }
    }
    if (state != DataSyncCommitState.applied &&
        outcomeReadable &&
        checkpoint != null) {
      state = DataSyncCommitState.recoveryRequired;
      try {
        final rollbackFailures = await _rollbackImport(
          transaction: transaction,
          reloadHistory: reloadHistory,
          reloadLocalFavorites: reloadLocalFavorites,
          reloadCookies: reloadCookies,
          reloadComicSources: reloadComicSources,
          checkpoint: checkpoint,
          publishImported: publishImported,
        );
        failures.addAll(rollbackFailures);
        if (rollbackFailures.isEmpty) state = DataSyncCommitState.notApplied;
      } catch (error, stack) {
        failures.add((stage: 'rollback import', error: error, stack: stack));
      }
    }
  } finally {
    final recoveryPath = transaction?.directoryPath;
    final cleanup = _ImportCleanup(
      [(stage: 'remove import staging', directory: cacheDir)],
      recoveryPath: recoveryPath,
      dataPath: App.dataPath,
      journalId: state == DataSyncCommitState.recoveryRequired
          ? null
          : transaction?.id,
    );
    try {
      journal?.close();
    } catch (error, stack) {
      failures.add((stage: 'close import journal', error: error, stack: stack));
    }
    final cleanupFailures = await cleanup.attempt();
    if (cleanupFailures.isNotEmpty) {
      failures.addAll(cleanupFailures);
      final failure = DataSyncImportFailure(
        commitState: state,
        failures: failures,
        recoveryPath: recoveryPath,
        resume: state == DataSyncCommitState.applied ? cleanup.resume : null,
      );
      Error.throwWithStackTrace(failure, failures.first.stack);
    }
  }
  if (failures.isNotEmpty) {
    if (!mutationStarted && failures.length == 1) {
      Error.throwWithStackTrace(failures.first.error, failures.first.stack);
    }
    Error.throwWithStackTrace(
      DataSyncImportFailure(
        commitState: state,
        failures: failures,
        recoveryPath: state == DataSyncCommitState.recoveryRequired
            ? transaction?.directoryPath
            : null,
      ),
      failures.first.stack,
    );
  }
  return state;
}

class _ImportCleanup {
  _ImportCleanup(
    this.pending, {
    required this.recoveryPath,
    required this.dataPath,
    required this.journalId,
  });
  final List<({String stage, Directory directory})> pending;
  final String? recoveryPath;
  final String dataPath;
  String? journalId;

  Future<List<DataSyncDiagnostic>> attempt() async {
    final failures = <DataSyncDiagnostic>[];
    for (final entry in pending.toList()) {
      try {
        if (await entry.directory.exists()) {
          await entry.directory.delete(recursive: true);
        }
        pending.remove(entry);
      } catch (error, stack) {
        failures.add((stage: entry.stage, error: error, stack: stack));
      }
    }
    if (journalId case final id?) {
      AppDataImportJournal? journal;
      try {
        journal = AppDataImportJournal.open(dataPath);
        await journal.cleanup(id);
        journalId = null;
      } catch (error, stack) {
        failures.add((
          stage: 'remove import backup',
          error: error,
          stack: stack,
        ));
      } finally {
        try {
          journal?.close();
        } catch (error, stack) {
          failures.add((
            stage: 'close cleanup journal',
            error: error,
            stack: stack,
          ));
        }
      }
    }
    return failures;
  }

  Future<DataSyncCommitState> resume() =>
      AppDataOperations.instance.run(() async {
        final failures = await attempt();
        if (failures.isNotEmpty) {
          throw DataSyncImportFailure(
            commitState: DataSyncCommitState.applied,
            failures: failures,
            recoveryPath: recoveryPath,
            resume: resume,
          );
        }
        return DataSyncCommitState.applied;
      });
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

Future<List<DataSyncDiagnostic>> _rollbackImport({
  required AppDataImportTransaction? transaction,
  required bool reloadHistory,
  required bool reloadLocalFavorites,
  required bool reloadCookies,
  required bool reloadComicSources,
  required AppdataImportCheckpoint checkpoint,
  void Function(void Function())? publishImported,
}) async {
  final failures = <DataSyncDiagnostic>[];
  Future<bool> attempt(String stage, FutureOr<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error, stack) {
      failures.add((stage: stage, error: error, stack: stack));
      return false;
    }
  }

  final historyClosed =
      !reloadHistory ||
      await attempt(
        'close history for rollback',
        _closeHistoryManagerForImport,
      );
  final favoritesClosed =
      !reloadLocalFavorites ||
      await attempt(
        'close favorites for rollback',
        _closeLocalFavoritesManagerForImport,
      );
  final cookiesClosed =
      !reloadCookies ||
      await attempt('close cookies for rollback', _closeCookieJarForImport);

  final unrestored = <String>{
    if (!historyClosed) 'history.db',
    if (!favoritesClosed) 'local_favorite.db',
    if (!cookiesClosed) 'cookie.db',
  };
  if (transaction != null) {
    await attempt('restore import files', () async {
      failures.addAll(await transaction.restore(skip: unrestored));
    });
    final outcomeReadable = await attempt('read restored resources', () {
      unrestored.addAll(transaction.unrestoredResources);
    });
    if (!outcomeReadable) {
      unrestored.addAll(const {
        'history.db',
        'local_favorite.db',
        'cookie.db',
        'comic_source',
      });
      return failures;
    }
  }
  await attempt(
    'restore appdata memory',
    () => appdata.restoreImportCheckpoint(checkpoint, persist: false),
  );

  if (reloadHistory && historyClosed && !unrestored.contains('history.db')) {
    await attempt('reopen restored history', () => HistoryManager().init());
  }
  if (reloadLocalFavorites &&
      favoritesClosed &&
      !unrestored.contains('local_favorite.db')) {
    await attempt(
      'reopen restored favorites',
      () => LocalFavoritesManager().init(publishChange: publishImported),
    );
  }
  if (reloadCookies && cookiesClosed && !unrestored.contains('cookie.db')) {
    await attempt('reopen restored cookies', _openCookieJarForImport);
  }
  if (reloadComicSources && !unrestored.contains('comic_source')) {
    await attempt(
      'reload restored comic sources',
      () => ComicSourceManager().reload(publishChange: publishImported),
    );
  }
  await attempt('save restored appdata', () => appdata.saveData(false));
  if (failures.isEmpty && transaction != null) {
    await attempt('mark import rolled back', transaction.markRolledBack);
  }
  return failures;
}

Future<void> _closeHistoryManagerForImport() async {
  final manager = HistoryManager.cache;
  if (manager == null) return;
  await manager.waitForAsyncWrites();
  manager.close();
}

Future<void> _closeLocalFavoritesManagerForImport() async {
  await LocalFavoritesManager.cache?.closeAndWait();
}

void _closeCookieJarForImport() {
  SingleInstanceCookieJar.instance?.dispose();
}

void _openCookieJarForImport() {
  SingleInstanceCookieJar(FilePath.join(App.dataPath, "cookie.db"));
}

Future<void> importPicaData(File file) => AppDataOperations.instance.run(
  () => importLegacyPicaArchive(file, cachePath: App.cachePath),
);
