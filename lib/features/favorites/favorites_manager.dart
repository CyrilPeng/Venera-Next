import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'network_favorite_import.dart';
import 'favorite_folder_import.dart';
import 'favorite_updates_service.dart';
import 'read_later_service.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'favorite_identity_index.dart';
import 'package:venera_next/foundation/file_replacement.dart';
import 'favorites_repository.dart';
import 'favorite_models.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'favorite_cover_cache.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'dart:io';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';

typedef FollowUpdatesChangeListener = void Function();

FollowUpdatesChangeListener? _followUpdatesChangeListener;

void registerFollowUpdatesChangeListener(
  FollowUpdatesChangeListener? listener,
) {
  _followUpdatesChangeListener = listener;
}

void _notifyFollowUpdatesChanged() {
  AppDataOperations.instance.publish(
    () => _followUpdatesChangeListener?.call(),
  );
}

class LocalFavoritesManager with ChangeNotifier {
  factory LocalFavoritesManager() => _cache ??= LocalFavoritesManager._create();

  LocalFavoritesManager._create();

  /// An independently owned store; it does not replace the default application store.
  factory LocalFavoritesManager.independent() =>
      LocalFavoritesManager._create();

  Future<void>? _mutationTail;

  /// Acquire global admission before joining this owner's local mutation queue.
  /// Paths and connection generations belong to admission, never late execution.
  Future<T> _mutate<T>(FutureOr<T> Function() action) =>
      AppDataOperations.instance.access(() {
        if (_database == null || _isClosed) {
          throw StateError('Favorites database is closed');
        }
        final generation = _connectionGeneration;
        final path = _dbPath;
        final result = Completer<T>();
        void execute() {
          Future<T>.sync(() {
            if (generation != _connectionGeneration ||
                path != _dbPath ||
                _isClosed) {
              throw StateError(
                'Favorites mutation belongs to a closed connection',
              );
            }
            return action();
          }).then(result.complete, onError: result.completeError);
        }

        final previous = _mutationTail;
        late Future<void> settled;
        settled = result.future
            .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
            .whenComplete(() {
              if (identical(_mutationTail, settled)) _mutationTail = null;
            });
        _mutationTail = settled;
        if (previous == null) {
          execute();
        } else {
          previous.then((_) => execute());
        }
        return result.future;
      });

  Future<void> updateOrder(List<String> folders) {
    final captured = List<String>.of(folders);
    return _mutate(() => _updateOrder(captured));
  }

  Future<void> addTagTo(String folder, String id, String tag) =>
      _mutate(() => _addTagTo(folder, id, tag));

  Future<String> createFolder(
    String name, [
    bool renameWhenInvalidName = false,
  ]) => _mutate(() => _createFolder(name, renameWhenInvalidName));

  Future<void> linkFolderToNetwork(
    String folder,
    String source,
    String networkFolder,
  ) => _mutate(() => _linkFolderToNetwork(folder, source, networkFolder));

  Future<bool> addComic(
    String folder,
    FavoriteItem comic, [
    int? order,
    String? updateTime,
  ]) {
    final captured = comic.detached();
    return _mutate(() => _addComic(folder, captured, order, updateTime));
  }

  /// One accepted selection commits atomically, then publishes its exact result.
  Future<int> addComics(String folder, Iterable<FavoriteItem> comics) {
    final captured = comics.map((comic) => comic.detached()).toList();
    return _mutate(() {
      final added = _commitFavoriteTransaction(
        () => runSqliteTransaction(_db, () {
          if (!existsFolder(folder)) {
            throw StateError('Favorite folder no longer exists');
          }
          final append =
              GlobalPreferenceStore(
                appdata.settings,
              ).read(FavoritePreferences.newFavoriteAddTo) ==
              'end';
          return [
            for (final comic in captured)
              if (_repository.addComic(
                folder,
                comic,
                translatedTags: _translateTags(comic.tags),
                append: append,
              ))
                comic,
          ];
        }),
      );
      if (added.isNotEmpty) {
        _publishCommittedFavorites([
          folder,
        ], added.map((comic) => (comic.id, comic.type.value)));
      }
      return added.length;
    });
  }

  /// Borrow this connection's path while holding its mutation queue. The
  /// callback commits an addition in a coordinated SQLite transaction and
  /// returns its exact identity; caches and notifications are published here.
  Future<void> addComicWithStorage(
    String folder,
    List<String> tags,
    FavoriteItem Function(
      String databasePath,
      String translatedTags,
      bool append,
    )
    commit,
  ) {
    final capturedTags = List<String>.of(tags);
    return _mutate(() {
      if (!existsFolder(folder)) {
        throw const FormatException('Favorite folder no longer exists');
      }
      final comic = commit(
        _dbPath,
        _translateTags(capturedTags),
        GlobalPreferenceStore(
              appdata.settings,
            ).read(FavoritePreferences.newFavoriteAddTo) ==
            'end',
      );
      // Read the committed count; do not increment a possibly stale cache after
      // a transaction that also changed another database.
      _publishCommittedFavorites([folder], [(comic.id, comic.type.value)]);
    });
  }

  Future<void> moveFavorite(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) => _mutate(() => _moveFavorite(sourceFolder, targetFolder, id, type));

  Future<void> batchMoveFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    final captured = items.map((item) => item.detached()).toList();
    return _mutate(
      () => _batchMoveFavorites(sourceFolder, targetFolder, captured),
    );
  }

  Future<void> batchCopyFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    final captured = items.map((item) => item.detached()).toList();
    return _mutate(
      () => _batchCopyFavorites(sourceFolder, targetFolder, captured),
    );
  }

  Future<void> deleteFolder(String name) => _mutate(() => _deleteFolder(name));

  Future<void> transferFavorites(
    String source,
    Iterable<String> targets,
    List<FavoriteItem> items, {
    required bool move,
  }) {
    final destinations = targets
        .where((folder) => folder != source)
        .toSet()
        .toList();
    final identities = items.map((item) => (item.id, item.type.value)).toList();
    return _mutate(() {
      if (destinations.isEmpty || identities.isEmpty) return;
      _commitFavoriteTransaction(
        () => _repository.transferToFolders(
          source,
          destinations,
          identities,
          move: move,
        ),
      );
      _publishCommittedFavorites([source, ...destinations], identities);
    });
  }

  Future<void> deleteComicWithId(String folder, String id, ComicType type) =>
      _mutate(() => _deleteComicWithId(folder, id, type));

  Future<void> batchDeleteComics(String folder, List<FavoriteItem> comics) {
    final captured = comics.map((item) => item.detached()).toList();
    return _mutate(() => _batchDeleteComics(folder, captured));
  }

  Future<int> removeInvalid({
    required bool Function(String id) localComicExists,
  }) => _mutate(() => _removeInvalid(localComicExists));

  Future<void> reorder(List<FavoriteItem> newFolder, String folder) {
    final captured = newFolder.map((item) => item.detached()).toList();
    return _mutate(() => _reorder(captured, folder));
  }

  Future<void> rename(String before, String after) =>
      _mutate(() => _rename(before, after));

  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) => _mutate(() {
    if (generation != null) _checkSourceGeneration(generation);
    checkActive?.call();
    _onRead(id, type);
  });

  Future<void> editTags(String id, String folder, List<String> tags) {
    final captured = List<String>.of(tags);
    return _mutate(() => _editTags(id, folder, captured));
  }

  int get connectionGeneration => _connectionGeneration;

  void _checkSourceGeneration(int generation) {
    if (generation != _connectionGeneration) {
      throw StateError(
        'Favorite source response belongs to a replaced database',
      );
    }
  }

  Future<void> updateInfo(
    String folder,
    FavoriteItem comic, {
    required int generation,
    void Function()? checkActive,
  }) {
    final captured = comic.detached();
    return _mutate(() {
      _checkSourceGeneration(generation);
      checkActive?.call();
      _updateInfo(folder, captured);
    });
  }

  Future<bool> applyFollowUpdate(
    String folder,
    FavoriteItem comic,
    String? updateTime, {
    required int generation,
    required void Function() checkActive,
  }) {
    final captured = comic.detached();
    return _mutate(() {
      _checkSourceGeneration(generation);
      checkActive();
      final updated = _repository.applyFollowUpdate(
        folder,
        captured,
        updateTime,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (updated) {
        _updates.recordCommittedUpdate(
          folder,
          captured.id,
          captured.type.value,
          true,
        );
      }
      return updated;
    });
  }

  Future<NetworkFavoriteImportCommit> importNetworkFavorites(
    String folder,
    String source,
    String folderId,
    List<FavoriteItem> items, {
    required bool oldToNew,
    void Function()? checkActive,
    int? generation,
  }) {
    final captured = items.map((item) => item.detached()).toList();
    return _mutate(() {
      if (generation != null) _checkSourceGeneration(generation);
      checkActive?.call();
      return _importNetworkFavorites(
        folder,
        source,
        folderId,
        captured,
        oldToNew: oldToNew,
      );
    });
  }

  Future<void> fromJson(String json) => _mutate(() => _fromJson(json));

  Future<bool> prepareTableForFollowUpdates(
    String table, {
    bool clearData = true,
    int? generation,
    bool Function()? isCurrent,
  }) => _mutate(() {
    if (generation != null) _checkSourceGeneration(generation);
    if (isCurrent?.call() == false) return false;
    _prepareTableForFollowUpdates(table, clearData);
    return true;
  });

  Future<void> updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
  ) => _mutate(() => _updateUpdateTime(folder, id, type, updateTime));

  Future<void> updateCheckTime(String folder, String id, ComicType type) =>
      _mutate(() => _updateCheckTime(folder, id, type));

  Future<void> markAsRead(String id, ComicType type, {bool notify = true}) =>
      _mutate(() => _markAsRead(id, type, notify: notify));

  /// The confirmation owns a folder and immutable identities. A later tracking
  /// selection must not redirect these writes to a different folder.
  Future<void> markAllAsRead(String folder, List<FavoriteItem> comics) {
    final identities = comics
        .map((comic) => (comic.id, comic.type.value))
        .toList();
    return _mutate(() async {
      _commitFavoriteTransaction(
        () => _repository.markComicsAsRead(folder, identities),
      );
      await _finishFolderMutation(() => appdata.saveData(), () => false);
    });
  }

  Future<void> setFollowUpdatesFolder(
    String? folder, {
    required int generation,
  }) => _mutate(() async {
    _checkSourceGeneration(generation);
    if (folder != null && !existsFolder(folder)) {
      throw StateError('Favorite folder no longer exists');
    }
    await _finishFolderMutation(
      () => appdata.updateSettings((draft) {
        _checkSourceGeneration(generation);
        if (folder != null && !existsFolder(folder)) {
          throw StateError('Favorite folder no longer exists');
        }
        draft[FavoritePreferences.followUpdatesFolder.key] = folder;
      }),
      () => true,
      commitState: PersistenceCommitState.unknown,
    );
  });

  /// Recheck a stale preview at the settings queue head. A newer selection or
  /// a folder restored while admission was blocked must remain untouched.
  Future<void> clearMissingFollowUpdatesFolder(
    String expected, {
    required int generation,
  }) => _mutate(() async {
    _checkSourceGeneration(generation);
    var changed = false;
    await _finishFolderMutation(
      () => appdata.updateSettings((draft) {
        _checkSourceGeneration(generation);
        if (draft[FavoritePreferences.followUpdatesFolder.key] == expected &&
            !existsFolder(expected)) {
          draft[FavoritePreferences.followUpdatesFolder.key] = null;
          changed = true;
        }
      }),
      () => changed,
      commitState: PersistenceCommitState.unknown,
    );
  });

  @override
  void notifyListeners() =>
      AppDataOperations.instance.publish(super.notifyListeners);

  static LocalFavoritesManager? _cache;

  static LocalFavoritesManager? get cache => _cache;

  Database? _database;

  Database get _db =>
      _database ?? (throw StateError('Favorites database is closed'));

  Future<void>? _initialization;
  Future<void>? _closing;
  Future<void>? _clearing;
  Future<void>? _clearRequest;
  final _pendingReads = <Future<void>>{};
  int _connectionGeneration = 0;

  FavoritesRepository get _repository => FavoritesRepository(_db);

  late String _dbPath;

  String get databasePath {
    if (_database == null || _isClosed) {
      throw StateError('Favorites database is closed');
    }
    return _dbPath;
  }

  /// Reconcile external additions before any import completion notifications.
  void refreshImportedFavorites(Map<String, List<FavoriteItem>> folders) {
    for (final folder in folders.keys) {
      counts[folder] = count(folder);
    }
    _refreshIdentityCounts(
      folders.values
          .expand((items) => items)
          .map((item) => (item.id, item.type.value)),
    );
    refreshUpdateIds();
  }

  void notifyImportedFavorites(Iterable<String> folders) {
    _publishFavoriteChanges([
      () => _syncFollowUpdatesIfAffected(folders),
      notifyListeners,
    ]);
  }

  Map<String, int> counts = {};

  final _identityIndex = FavoriteIdentityIndex();

  late final _updates = FavoriteUpdatesService(
    repository: () => _repository,
    folder: () => GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.followUpdatesFolder),
  );

  Future<void>? _hashedIdsRefresh;
  final _pendingSettingsRepairs = <String>{};

  bool _isClosed = true;

  int get totalComics {
    return _identityIndex.length;
  }

  int folderComics(String folder) {
    return counts[folder] ?? 0;
  }

  Future<void> init({void Function(void Function())? publishChange}) =>
      AppDataOperations.instance.access(
        () => _initializeAfterTransitions(
          '${App.dataPath}/local_favorite.db',
          publishChange: publishChange,
        ),
      );

  Future<void> _initializeAfterTransitions(
    String path, {
    void Function(void Function())? publishChange,
  }) {
    final clearing = _clearing;
    if (clearing != null) {
      if (path != _dbPath) {
        return Future.error(
          StateError('Favorites is clearing a different data path'),
        );
      }
      return clearing;
    }
    final closing = _closing;
    if (closing != null) {
      return closing.then(
        (_) => _initializeAfterTransitions(path, publishChange: publishChange),
      );
    }
    return _startInitialization(path, publishChange: publishChange);
  }

  Future<void> _startInitialization(
    String path, {
    void Function(void Function())? publishChange,
    bool retryPendingSettings = true,
  }) {
    final existing = _initialization;
    if (existing != null) {
      if (_dbPath != path) {
        return Future.error(
          StateError('Close favorites before changing its data path'),
        );
      }
      return existing;
    }
    final attempt = Completer<void>();
    _initialization = attempt.future;
    _dbPath = path;
    final generation = ++_connectionGeneration;
    Future<void>.sync(
      () => _initialize(
        path,
        generation,
        publishChange: publishChange,
        retryPendingSettings: retryPendingSettings,
      ),
    ).then(
      (_) {
        if (generation != _connectionGeneration) {
          attempt.completeError(
            StateError('Favorites initialization was closed'),
          );
        } else {
          attempt.complete();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_initialization, attempt.future)) {
          _initialization = null;
        }
        attempt.completeError(error, stack);
      },
    );
    return attempt.future;
  }

  void _checkInitialization(int generation) {
    if (_connectionGeneration != generation) {
      throw StateError('Favorites initialization was closed');
    }
  }

  Future<void> _initialize(
    String path,
    int generation, {
    void Function(void Function())? publishChange,
    bool retryPendingSettings = true,
  }) async {
    Database? database;
    var published = false;
    try {
      if (App.isInitialized) await appdata.ensureInit();
      _checkInitialization(generation);
      final databaseExisted = File(path).existsSync();
      database = openSqliteDatabase(path);
      final repository = FavoritesRepository(database);
      repository.initializeMetadata();
      final folders = repository.folderNames();
      repository.migrateTranslatedTags(folders, _translateTags);
      if (!databaseExisted && folders.isEmpty) {
        repository.createFolder(trackingFolderName);
        folders.add(trackingFolderName);
      }
      void prepareTracking(Object? folder) {
        if (folder is String && repository.folderNames().contains(folder)) {
          repository.prepareForFollowUpdates(folder, clearData: false);
        }
      }

      prepareTracking(
        appdata.settings[FavoritePreferences.followUpdatesFolder.key],
      );
      if (!databaseExisted) prepareTracking(trackingFolderName);
      _checkInitialization(generation);
      _database = database;
      published = true;
      _isClosed = false;
      _identityIndex.clear();
      counts = {};
      final retryingWrite =
          retryPendingSettings && _pendingSettingsRepairs.contains(path);
      var changed = false;
      try {
        while (true) {
          final unprepared = await appdata.updateSettings(
            (draft) {
              _checkInitialization(generation);
              final available = repository.folderNames();
              String? resolve(Object? value) =>
                  value is String && available.contains(value)
                  ? value
                  : !databaseExisted && available.contains(trackingFolderName)
                  ? trackingFolderName
                  : null;
              final tracking = resolve(
                draft[FavoritePreferences.followUpdatesFolder.key],
              );
              final quick = resolve(
                draft[FavoritePreferences.quickFavorite.key],
              );
              // A preceding queued edit may select another valid folder. Prepare
              // its schema outside the draft before publishing any repaired value.
              if (tracking != null &&
                  !repository.isPreparedForFollowUpdates(tracking)) {
                return tracking;
              }
              changed =
                  draft[FavoritePreferences.followUpdatesFolder.key] !=
                      tracking ||
                  draft[FavoritePreferences.quickFavorite.key] != quick;
              if (draft[FavoritePreferences.followUpdatesFolder.key] !=
                  tracking) {
                draft[FavoritePreferences.followUpdatesFolder.key] = tracking;
              }
              if (draft[FavoritePreferences.quickFavorite.key] != quick) {
                draft[FavoritePreferences.quickFavorite.key] = quick;
              }
              return null;
            },
            sync: false,
            persistIfUnchanged: false,
          );
          _checkInitialization(generation);
          if (unprepared == null) break;
          prepareTracking(unprepared);
        }
        if (retryingWrite && !changed) await appdata.saveData(false);
        if (changed || retryingWrite) _pendingSettingsRepairs.remove(path);
      } catch (_) {
        _pendingSettingsRepairs.add(path);
        rethrow;
      }
      _checkInitialization(generation);
      await _initCounts(publishChange: publishChange);
    } catch (_) {
      if (!published) {
        database?.dispose();
      } else if (identical(_database, database)) {
        close();
      }
      rethrow;
    }
  }

  Future<void> _initCounts({
    void Function(void Function())? publishChange,
  }) async {
    for (var folder in folderNames) {
      counts[folder] = count(folder);
    }
    refreshUpdateIds();
    await _refreshHashedIds(publishChange: publishChange);
  }

  Future<void> refreshHashedIds() => _refreshHashedIds();

  static const String trackingFolderName = "追更";

  late final _readLater = ReadLaterService(
    repository: () => _repository,
    configuredFolder: () => GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.readLaterFolder),
    translateTags: _translateTags,
  );

  String? get readLaterFolder => _readLater.folder;

  bool isInReadLater(String id, ComicType type) =>
      _readLater.contains(id, type);

  List<FavoriteItem> getReadLaterComics({int? limit}) =>
      _readLater.comics(limit: limit);

  Future<void> setReadLater(
    FavoriteItem comic, {
    required bool included,
    required String folderName,
  }) {
    final captured = comic.detached();
    // This short compound operation changes SQL and its settings reference.
    // Acquire exclusion before the local queue; no network work occurs here.
    return AppDataOperations.instance.run(
      () => _mutate(() async {
        final generation = _connectionGeneration;
        late ReadLaterCommit commit;
        try {
          commit = _readLater.set(
            captured,
            included: included,
            folderName: folderName,
          );
        } on SqliteTransactionRollbackError catch (error, stack) {
          Error.throwWithStackTrace(
            PersistenceFailure(
              commitState: PersistenceCommitState.unknown,
              cause: error.operationError,
              stackTrace: error.operationStack,
              cleanupFailures: [
                (error: error.rollbackError, stackTrace: error.rollbackStack),
              ],
            ),
            stack,
          );
        }
        final failures = <({Object error, StackTrace stackTrace})>[];
        try {
          await appdata.updateSettings((draft) {
            _checkSourceGeneration(generation);
            if (commit.created) {
              draft[FavoritePreferences.readLaterFolder.key] = commit.folder;
            }
          });
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
        }
        try {
          final folder = commit.folder;
          if (folder != null && (commit.created || commit.added)) {
            _publishCommittedFavorites(
              [folder],
              [(captured.id, captured.type.value)],
            );
          } else if (folder != null && commit.removed) {
            _applyDeletedComics({
              folder: [(captured.id, captured.type.value)],
            });
          }
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
        }
        if (failures.isNotEmpty) {
          if (failures.length == 1) {
            _throwCommittedFailure(
              failures.single.error,
              failures.single.stackTrace,
            );
          }
          Error.throwWithStackTrace(
            PersistenceFailure(
              commitState: PersistenceCommitState.committed,
              cause: failures.first.error,
              stackTrace: failures.first.stackTrace,
              cleanupFailures: failures.skip(1),
            ),
            failures.first.stackTrace,
          );
        }
      }),
    );
  }

  Future<void> _refreshHashedIds({
    void Function(void Function())? publishChange,
  }) {
    late Future<void> refresh;
    refresh = _mutate(() async {
      final folders = folderNames;
      final generation = _identityIndex.beginRefresh();
      try {
        if (folders.isEmpty) {
          _identityIndex.completeRefresh(generation, {});
          return;
        }
        final value = await _startRead((path) => _initHashedIds(folders, path));
        if (_isClosed || !_identityIndex.completeRefresh(generation, value)) {
          return;
        }
        if (publishChange == null) {
          notifyListeners();
        } else {
          AppDataOperations.instance.publish(
            () => publishChange(notifyListeners),
          );
        }
      } catch (_) {
        _identityIndex.failRefresh(generation);
        rethrow;
      }
    });
    refresh.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (!_isClosed && identical(_hashedIdsRefresh, refresh)) {
          Log.error('LocalFavoritesManager', error, stack);
        }
      },
    );
    _hashedIdsRefresh = refresh;
    return refresh;
  }

  @visibleForTesting
  Future<void> debugWaitForHashedIdsRefresh() async {
    // Initialization may still be queued behind settings before starting its
    // identity read. Do not accidentally await the previous connection's read.
    await _initialization;
    await _hashedIdsRefresh;
  }

  void refreshUpdateIds() => _updates.refresh();

  void _syncFollowUpdatesIfAffected(Iterable<String> folders) {
    var folder = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.followUpdatesFolder);
    if (folder == null || !folders.contains(folder)) {
      return;
    }
    refreshUpdateIds();
    _notifyFollowUpdatesChanged();
  }

  void _refreshIdentityCounts(Iterable<(String, int)> identities) {
    final requested = identities.toSet();
    final counts = _repository.referenceCounts(folderNames, requested);
    for (final identity in requested) {
      _identityIndex.setCount(identity, counts[identity] ?? 0);
    }
  }

  static Future<Map<(String, int), int>> _initHashedIds(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        var identities = <(String, int), int>{};
        for (var folder in folders) {
          for (final (id, type) in FavoritesRepository(db).identities(folder)) {
            final identity = (id, type);
            identities[identity] = (identities[identity] ?? 0) + 1;
          }
        }
        return identities;
      } finally {
        db.dispose();
      }
    });
  }

  List<String> find(String id, ComicType type) =>
      _repository.findFolders(folderNames, id, type.value);

  Future<List<String>> findWithModel(FavoriteItem item) {
    final id = item.id;
    final type = item.type;
    return _mutate(() => find(id, type));
  }

  void _updateOrder(List<String> folders) {
    _repository.updateOrder(folders);
    notifyListeners();
  }

  int count(String folderName) => _repository.count(folderName);

  List<String> get folderNames => _repository.folderNames();

  int maxValue(String folder) => _repository.maxValue(folder);

  int minValue(String folder) => _repository.minValue(folder);

  List<FavoriteItem> getFolderComics(String folder) =>
      _repository.getFolderComics(folder);

  Future<T> _runRead<T>(Future<T> Function(String path) read) =>
      _mutate(() => _startRead(read));

  Future<T> _startRead<T>(Future<T> Function(String path) read) {
    if (_database == null || _isClosed) {
      return Future.error(StateError('Favorites database is closed'));
    }
    final generation = _connectionGeneration;
    final path = _dbPath;
    final result = Future<T>.sync(() => read(path)).then((value) {
      if (generation != _connectionGeneration || _isClosed) {
        throw StateError('Favorites read belongs to a closed connection');
      }
      return value;
    });
    // Observe completion for draining without consuming the caller's error.
    late Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
        .whenComplete(() => _pendingReads.remove(settled));
    _pendingReads.add(settled);
    return result;
  }

  static Future<List<FavoriteItem>> _getFolderComicsAsync(
    String folder,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        return FavoritesRepository(db).getFolderComics(folder);
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get the comics in the folder
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    return _runRead((path) => _getFolderComicsAsync(folder, path));
  }

  List<FavoriteItem> getAllComics() => _repository.getAllComics(folderNames);

  static Future<List<FavoriteItem>> _getAllComicsAsync(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        return FavoritesRepository(db).getAllComics(folders);
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get all the comics
  Future<List<FavoriteItem>> getAllComicsAsync() {
    return _runRead((path) => _getAllComicsAsync(folderNames, path));
  }

  void _addTagTo(String folder, String id, String tag) {
    _repository.addTagTo(folder, id, tag);
    notifyListeners();
  }

  List<FavoriteItemWithFolderInfo> allComics() =>
      _repository.allComics(folderNames);

  bool existsFolder(String name) {
    return folderNames.contains(name);
  }

  /// create a folder
  String _createFolder(String name, [bool renameWhenInvalidName = false]) {
    if (name.isEmpty) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw OperationFailure.message("name is empty!");
      }
    }
    if (existsFolder(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    _repository.createFolder(name);
    counts[name] = 0;
    notifyListeners();
    return name;
  }

  void _linkFolderToNetwork(
    String folder,
    String source,
    String networkFolder,
  ) => _repository.linkFolderToNetwork(folder, source, networkFolder);

  bool isLinkedToNetworkFolder(
    String folder,
    String source,
    String networkFolder,
  ) => _repository.isLinkedToNetworkFolder(folder, source, networkFolder);

  (String?, String?) findLinked(String folder) =>
      _repository.findLinked(folder);

  bool comicExists(String folder, String id, ComicType type) =>
      _repository.comicExists(folder, id, type.value);

  FavoriteItem getComic(String folder, String id, ComicType type) =>
      _repository.findComic(folder, id, type.value) ??
      (throw Exception("Comic not found"));

  String _translateTags(List<String> tags) {
    var res = <String>[];
    for (var tag in tags) {
      var translated = tag.translateTagsToCN;
      if (translated != tag) {
        res.add(translated);
      }
    }
    return res.join(",");
  }

  /// add comic to a folder.
  /// return true if success, false if already exists
  bool _addComic(
    String folder,
    FavoriteItem comic, [
    int? order,
    String? updateTime,
  ]) {
    if (!existsFolder(folder)) {
      throw Exception("Folder does not exists");
    }
    final added = _repository.addComic(
      folder,
      comic,
      translatedTags: _translateTags(comic.tags),
      append:
          GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.newFavoriteAddTo) ==
          "end",
      order: order,
      updateTime: updateTime,
    );
    if (!added) return false;
    _publishCommittedFavorites([folder], [(comic.id, comic.type.value)]);
    return true;
  }

  void _moveFavorite(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    if (!_repository.moveFavorite(sourceFolder, targetFolder, id, type.value)) {
      return;
    }

    _publishCommittedFavorites(
      [sourceFolder, targetFolder],
      [(id, type.value)],
    );
  }

  void _batchMoveFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }
    if (items.isEmpty || sourceFolder == targetFolder) {
      return;
    }

    try {
      _repository.moveMany(
        sourceFolder,
        targetFolder,
        items.map((item) => (item.id, item.type.value)),
      );
    } catch (e) {
      Log.error("Batch Move Favorites", e.toString());
      rethrow;
    }

    _publishCommittedFavorites([
      sourceFolder,
      targetFolder,
    ], items.map((item) => (item.id, item.type.value)));
  }

  void _batchCopyFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }
    if (items.isEmpty || sourceFolder == targetFolder) {
      return;
    }

    try {
      _repository.copyMany(
        sourceFolder,
        targetFolder,
        items.map((item) => (item.id, item.type.value)),
      );
    } catch (e) {
      Log.error("Batch Copy Favorites", e.toString());
      rethrow;
    }

    _publishCommittedFavorites([
      targetFolder,
    ], items.map((item) => (item.id, item.type.value)));
  }

  /// delete a folder
  Future<void> _deleteFolder(String name) async {
    final removedIdentities = _repository.identities(name);
    _commitFavoriteTransaction(() => _repository.deleteFolder(name));
    try {
      counts.remove(name);
      _refreshIdentityCounts(removedIdentities);
      var followChanged = false;
      await _finishFolderMutation(
        () => appdata.updateSettings((draft) {
          for (final key in [
            FavoritePreferences.readLaterFolder.key,
            FavoritePreferences.quickFavorite.key,
            FavoritePreferences.followUpdatesFolder.key,
          ]) {
            if (draft[key] == name) {
              draft[key] = null;
              if (key == FavoritePreferences.followUpdatesFolder.key) {
                followChanged = true;
              }
            }
          }
        }),
        () => followChanged,
      );
    } catch (error, stack) {
      _throwCommittedFailure(error, stack);
    }
  }

  T _commitFavoriteTransaction<T>(T Function() commit) {
    try {
      return commit();
    } on SqliteTransactionRollbackError catch (error, stack) {
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.unknown,
          cause: error.operationError,
          stackTrace: error.operationStack,
          cleanupFailures: [
            (error: error.rollbackError, stackTrace: error.rollbackStack),
          ],
        ),
        stack,
      );
    } catch (error, stack) {
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.notCommitted,
          cause: error,
          stackTrace: stack,
        ),
        stack,
      );
    }
  }

  Never _throwCommittedFailure(Object error, StackTrace stack) {
    if (error is PersistenceFailure &&
        error.commitState == PersistenceCommitState.committed) {
      Error.throwWithStackTrace(error, stack);
    }
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: PersistenceCommitState.committed,
        cause: error,
        stackTrace: stack,
      ),
      stack,
    );
  }

  void _publishCommittedFavorites(
    Iterable<String> folders,
    Iterable<(String, int)> identities,
  ) {
    final affected = folders.toSet();
    _publishFavoriteChanges([
      for (final folder in affected) () => counts[folder] = count(folder),
      () => _refreshIdentityCounts(identities),
      () => _syncFollowUpdatesIfAffected(affected),
      notifyListeners,
    ]);
  }

  /// A committed write is not undone by an observer failure. Attempt each
  /// independent publication and preserve all failures for the original owner.
  void _publishFavoriteChanges(
    Iterable<void Function()> actions, {
    Iterable<({Object error, StackTrace stackTrace})> priorFailures = const [],
    PersistenceCommitState commitState = PersistenceCommitState.committed,
  }) {
    final failures = [...priorFailures];
    for (final action in actions) {
      try {
        action();
      } catch (error, stack) {
        failures.add((error: error, stackTrace: stack));
      }
    }

    if (failures.isNotEmpty) {
      final first = failures.first;
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: commitState,
          cause: first.error,
          stackTrace: first.stackTrace,
          cleanupFailures: failures.skip(1),
        ),
        first.stackTrace,
      );
    }
  }

  /// SQL may already be committed. Publish the resulting state even if the
  /// settings draft cannot persist, retaining the outcome and all failures.
  Future<void> _finishFolderMutation(
    Future<void> Function() saveSettings,
    bool Function() followChanged, {
    PersistenceCommitState commitState = PersistenceCommitState.committed,
  }) async {
    final failures = <({Object error, StackTrace stackTrace})>[];
    try {
      await saveSettings();
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    _publishFavoriteChanges(
      [
        refreshUpdateIds,
        () {
          if (followChanged()) _notifyFollowUpdatesChanged();
        },
        notifyListeners,
      ],
      priorFailures: failures,
      commitState: commitState,
    );
  }

  void _applyDeletedComics(Map<String, List<(String, int)>> removed) {
    if (removed.isEmpty) return;
    final identities = removed.values.expand((items) => items).toSet();
    _publishFavoriteChanges([
      for (final folder in removed.keys) () => counts[folder] = count(folder),
      () => _refreshIdentityCounts(identities),
      () {
        // Covers are shared across folders and cannot participate in rollback.
        // Release them only after commit and after checking the last reference.
        final folders = folderNames;
        for (final (id, type) in identities) {
          if (_repository.findFolders(folders, id, type).isNotEmpty) continue;
          try {
            deleteFavoriteCover(
              dataDirectory: App.dataPath,
              id: id,
              intKey: type,
            );
          } catch (error, stack) {
            Log.error('Favorite cover cleanup', error, stack);
          }
        }
      },
      () => _syncFollowUpdatesIfAffected(removed.keys),
      notifyListeners,
    ]);
  }

  /// Publish deletions committed by a coordinated database transaction.
  void refreshDeletedFavorites(Map<String, List<(String, int)>> removed) =>
      _applyDeletedComics(removed);

  void _deleteComicWithId(String folder, String id, ComicType type) {
    _applyDeletedComics(_repository.deleteComics([folder], [(id, type.value)]));
  }

  void _batchDeleteComics(String folder, List<FavoriteItem> comics) {
    if (comics.isEmpty) return;
    late Map<String, List<(String, int)>> removed;
    try {
      removed = _commitFavoriteTransaction(
        () => _repository.deleteComics([
          folder,
        ], comics.map((comic) => (comic.id, comic.type.value))),
      );
    } catch (error) {
      Log.error('Batch Delete Comics', error.toString());
      rethrow;
    }
    try {
      _applyDeletedComics(removed);
    } catch (error, stack) {
      _throwCommittedFailure(error, stack);
    }
  }

  Future<int> _removeInvalid(bool Function(String id) localComicExists) async {
    int count = 0;
    await Future.microtask(() {
      var all = allComics();
      for (var c in all) {
        var comicSource = c.type.comicSource;
        if ((c.type == ComicType.local && !localComicExists(c.id)) ||
            (c.type != ComicType.local && comicSource == null)) {
          _deleteComicWithId(c.folder, c.id, c.type);
          count++;
        }
      }
    });
    return count;
  }

  Future<void> clearAll() {
    final existing = _clearRequest;
    if (existing != null) return existing;
    if (_database == null || _isClosed) {
      return Future.error(StateError('Favorites database is closed'));
    }
    final path = _dbPath;
    final attempt = Completer<void>();
    _clearRequest = attempt.future;
    AppDataOperations.instance
        .run(() async {
          if (_dbPath != path) {
            throw StateError('Favorites clear belongs to another data path');
          }
          _clearing = attempt.future;
          await _clearDatabase(path);
        })
        .then(
          (_) {
            _clearing = null;
            _clearRequest = null;
            attempt.complete();
          },
          onError: (Object error, StackTrace stack) {
            _clearing = null;
            _clearRequest = null;
            attempt.completeError(error, stack);
          },
        );
    return attempt.future;
  }

  Future<void> _clearDatabase(String path) async {
    final previousTracking =
        appdata.settings[FavoritePreferences.followUpdatesFolder.key];
    final previousQuick =
        appdata.settings[FavoritePreferences.quickFavorite.key];
    await _closeAndWait();
    Directory? backupDirectory;
    FileReplacement? replacement;
    var prepared = false;
    try {
      backupDirectory = File(path).parent.createTempSync('.favorite_clear_');
      replacement = FileReplacement(
        path,
        '${backupDirectory.path}/local_favorite.db',
      );
      replacement.backup();
      prepared = true;
      await _startInitialization(path);
    } catch (error, stack) {
      final failures = <({Object error, StackTrace stackTrace})>[];
      Future<bool> recover(FutureOr<void> Function() action) async {
        try {
          await action();
          return true;
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
          return false;
        }
      }

      final closed = await recover(_closeAndWait);
      final restored =
          closed && (!prepared || await recover(() => replacement!.restore()));
      await recover(
        () => appdata.restoreSettingsFields({
          FavoritePreferences.followUpdatesFolder.key: previousTracking,
          FavoritePreferences.quickFavorite.key: previousQuick,
        }, persist: false),
      );
      if (restored) {
        // An unavailable settings file must not prevent reopening the restored
        // database. The separate flush below still reports durability failure.
        await recover(
          () => _startInitialization(path, retryPendingSettings: false),
        );
      }
      if (await recover(() => appdata.saveData(false))) {
        _pendingSettingsRepairs.remove(path);
      } else {
        _pendingSettingsRepairs.add(path);
      }
      // An unsuccessful restore must retain its backup for manual recovery.
      if (replacement == null || !replacement.backupFile.existsSync()) {
        await recover(() => _removeClearBackupDirectory(backupDirectory));
      }
      if (failures.isNotEmpty) {
        Error.throwWithStackTrace(
          PersistenceFailure(
            commitState: PersistenceCommitState.unknown,
            cause: error,
            stackTrace: stack,
            cleanupFailures: failures,
          ),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    final failures = <({Object error, StackTrace stackTrace})>[];
    try {
      replacement.commit();
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    try {
      _removeClearBackupDirectory(backupDirectory);
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    if (failures.isNotEmpty) {
      // Clearing succeeded; cleanup failures must not roll back the new DB.
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: failures.first.error,
          stackTrace: failures.first.stackTrace,
          cleanupFailures: failures.skip(1),
        ),
        failures.first.stackTrace,
      );
    }
  }

  void _removeClearBackupDirectory(Directory? directory) {
    if (directory == null || !directory.existsSync()) return;
    directory.deleteSync();
  }

  void _reorder(List<FavoriteItem> newFolder, String folder) {
    if (!existsFolder(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    try {
      _repository.reorder(
        folder,
        newFolder.map((item) => (item.id, item.type.value)),
      );
    } catch (e) {
      Log.error("Reorder", e.toString());
      rethrow;
    }
    notifyListeners();
  }

  Future<void> _rename(String before, String after) async {
    if (existsFolder(after)) {
      throw OperationFailure.message("Name already exists!");
    }
    if (after.contains('"')) {
      throw OperationFailure.message("Invalid name");
    }
    _repository.renameFolder(before, after);
    counts[after] = counts[before] ?? 0;
    counts.remove(before);
    var followChanged = false;
    await _finishFolderMutation(
      () => appdata.updateSettings((draft) {
        for (final key in [
          FavoritePreferences.readLaterFolder.key,
          FavoritePreferences.quickFavorite.key,
          FavoritePreferences.followUpdatesFolder.key,
        ]) {
          if (draft[key] == before) {
            draft[key] = after;
            if (key == FavoritePreferences.followUpdatesFolder.key) {
              followChanged = true;
            }
          }
        }
      }),
      () => followChanged,
    );
  }

  void _onRead(String id, ComicType type) {
    final movement = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.moveFavoriteAfterRead);
    if (movement == "none") {
      _markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.followUpdatesFolder);
    final changed = _repository.recordRead(
      folderNames.where((folder) => folder != readLaterFolder),
      id,
      type.value,
      time: DateTime.now()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .substring(0, 19),
      movement: movement,
      trackingFolder: followUpdatesFolder,
    );
    _publishFavoriteChanges([
      if (changed.contains(followUpdatesFolder)) ...[
        () => _updates.recordCommittedRead(id, type.value),
        _notifyFollowUpdatesChanged,
      ],
      notifyListeners,
    ]);
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) =>
      _repository.searchInFolder(folder, keyword);

  List<FavoriteItem> search(String keyword) =>
      _repository.search(folderNames, keyword);

  void _editTags(String id, String folder, List<String> tags) {
    _repository.editTags(folder, id, tags);
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    return _identityIndex.contains(id, type.value);
  }

  bool hasNewUpdate(String id, ComicType type) =>
      _updates.contains(id, type.value);

  void _updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
    _commitFavoriteTransaction(() => _repository.updateInfo(folder, comic));
    if (notify) {
      try {
        notifyListeners();
      } catch (error, stack) {
        _throwCommittedFailure(error, stack);
      }
    }
  }

  String folderToJson(String folder) {
    return jsonEncode({
      "info": "Generated by VeneraNext",
      "name": folder,
      "comics": _repository
          .exportComics(folder)
          .map((item) => item.toJson())
          .toList(),
    });
  }

  NetworkFavoriteImportCommit _importNetworkFavorites(
    String folder,
    String source,
    String folderId,
    List<FavoriteItem> items, {
    required bool oldToNew,
  }) {
    final added = commitNetworkFavorites(
      _repository,
      folder: folder,
      source: source,
      folderId: folderId,
      items: items,
      append:
          GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.newFavoriteAddTo) ==
          'end',
      oldToNew: oldToNew,
      translateTags: _translateTags,
    );
    return NetworkFavoriteImportCommit(
      folder,
      added,
      owner: this,
      generation: _connectionGeneration,
    );
  }

  /// Retryable publication of an already committed import; never writes SQL.
  Future<void> publishNetworkFavoriteImport(
    NetworkFavoriteImportCommit result,
  ) => _mutate(() {
    // Reopening rebuilds the current cache. An old receipt has no authority to
    // publish into that connection, even when the path and folder are reused.
    if (!identical(result.owner, this) ||
        result.generation != _connectionGeneration) {
      return;
    }
    _publishFavoriteChanges([
      () => counts[result.folder] = count(result.folder),
      () => _refreshIdentityCounts(result.identities),
      refreshUpdateIds,
      () => _syncFollowUpdatesIfAffected([result.folder]),
      notifyListeners,
    ]);
  });

  void _fromJson(String json) {
    final (folder, comics) = importFavoriteFolder(
      json,
      _repository,
      append:
          GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.newFavoriteAddTo) ==
          'end',
      translateTags: _translateTags,
    );
    _publishFavoriteChanges([
      () => refreshImportedFavorites({folder: comics}),
      () => _syncFollowUpdatesIfAffected([folder]),
      notifyListeners,
    ]);
  }

  void _prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    _repository.prepareForFollowUpdates(table, clearData: clearData);
    if (GlobalPreferenceStore(
          appdata.settings,
        ).read(FavoritePreferences.followUpdatesFolder) ==
        table) {
      refreshUpdateIds();
    }
  }

  void _updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
  ) {
    final hasNewUpdate = _repository.updateUpdateTime(
      folder,
      id,
      type.value,
      updateTime,
      DateTime.now().millisecondsSinceEpoch,
    );
    _updates.recordCommittedUpdate(folder, id, type.value, hasNewUpdate);
  }

  void _updateCheckTime(String folder, String id, ComicType type) =>
      _repository.updateCheckTime(
        folder,
        id,
        type.value,
        DateTime.now().millisecondsSinceEpoch,
      );

  int countUpdates(String folder) => _repository.countUpdates(folder);

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) =>
      existsFolder(folder) ? _repository.getComicsWithUpdatesInfo(folder) : [];

  void _markAsRead(String id, ComicType type, {bool notify = true}) {
    var folder = GlobalPreferenceStore(
      appdata.settings,
    ).read(FavoritePreferences.followUpdatesFolder);
    if (folder == null || !existsFolder(folder)) {
      return;
    }
    _repository.markAsRead(folder, id, type.value);
    if (notify) {
      _publishFavoriteChanges([
        () => _updates.recordCommittedRead(id, type.value),
        _notifyFollowUpdatesChanged,
        notifyListeners,
      ]);
    } else {
      _updates.recordCommittedRead(id, type.value);
    }
  }

  /// Freeze new accesses and wait for accepted reads/writes before closing.
  Future<void> closeAndWait() =>
      AppDataOperations.instance.run(() => _closeAfterClear());

  Future<void> _closeAfterClear() {
    final clearing = _clearing;
    if (clearing != null) {
      return clearing.then(
        (_) => _closeAndWait(),
        onError: (Object error, StackTrace stack) => _closeAndWait(),
      );
    }
    return _closeAndWait();
  }

  Future<void> _closeAndWait() {
    final existing = _closing;
    if (existing != null) return existing;
    close();
    late Future<void> closing;
    closing = Future.wait(List<Future<void>>.of(_pendingReads))
        .then<void>((_) {})
        .whenComplete(() {
          if (identical(_closing, closing)) _closing = null;
        });
    _closing = closing;
    return closing;
  }

  void close() => AppDataOperations.instance.accessSync(_closeImmediately);

  void _closeImmediately() {
    _connectionGeneration++;
    _initialization = null;
    _isClosed = true;
    _identityIndex.clear();
    _updates.clear();
    counts.clear();
    final database = _database;
    _database = null;
    database?.dispose();
  }

  void notifyChanges() {
    refreshUpdateIds();
    notifyListeners();
  }
}
