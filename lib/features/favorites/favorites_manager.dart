import 'network_favorite_import.dart';
import 'favorite_folder_import.dart';
import 'favorite_updates_service.dart';
import 'read_later_service.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
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
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'dart:io';

import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
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
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

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
      _repository.transferToFolders(
        source,
        destinations,
        identities,
        move: move,
      );
      for (final folder in [source, ...destinations]) {
        counts[folder] = count(folder);
      }
      _refreshIdentityCounts(identities);
      _syncFollowUpdatesIfAffected([source, ...destinations]);
      notifyListeners();
    });
  }

  Future<void> deleteComicWithId(String folder, String id, ComicType type) =>
      _mutate(() => _deleteComicWithId(folder, id, type));

  Future<void> batchDeleteComics(String folder, List<FavoriteItem> comics) {
    final captured = comics.map((item) => item.detached()).toList();
    return _mutate(() => _batchDeleteComics(folder, captured));
  }

  Future<int> removeInvalid() => _mutate(_removeInvalid);

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

  Future<void> prepareTableForFollowUpdates(
    String table, [
    bool clearData = true,
  ]) => _mutate(() => _prepareTableForFollowUpdates(table, clearData));

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

  Future<void> setFollowUpdatesFolder(
    String? folder, {
    required int generation,
  }) => _mutate(() async {
    _checkSourceGeneration(generation);
    if (folder != null && !existsFolder(folder)) {
      throw StateError('Favorite folder no longer exists');
    }
    appdata.settings['followUpdatesFolder'] = folder;
    refreshUpdateIds();
    await _finishFolderMutation(
      true,
      true,
      commitState: PersistenceCommitState.unknown,
    );
  });

  @override
  void notifyListeners() =>
      AppDataOperations.instance.publish(super.notifyListeners);

  static LocalFavoritesManager? cache;

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
    _syncFollowUpdatesIfAffected(folders);
    notifyListeners();
  }

  Map<String, int> counts = {};

  final _identityIndex = FavoriteIdentityIndex();

  late final _updates = FavoriteUpdatesService(
    repository: () => _repository,
    folder: () => appdata.settings['followUpdatesFolder'],
  );

  Future<void>? _hashedIdsRefresh;

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
      () => _initialize(path, generation, publishChange: publishChange),
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
      final configuredTrackingFolder = appdata.settings['followUpdatesFolder'];
      final trackingFolder =
          configuredTrackingFolder is String &&
              folders.contains(configuredTrackingFolder)
          ? configuredTrackingFolder
          : !databaseExisted && folders.contains(trackingFolderName)
          ? trackingFolderName
          : null;
      if (trackingFolder != null) {
        repository.prepareForFollowUpdates(trackingFolder, clearData: false);
      }
      final quickFavorite = appdata.settings['quickFavorite'];
      final nextQuickFavorite =
          quickFavorite is String && folders.contains(quickFavorite)
          ? quickFavorite
          : !databaseExisted && folders.contains(trackingFolderName)
          ? trackingFolderName
          : null;
      final settingsChanged =
          configuredTrackingFolder != trackingFolder ||
          quickFavorite != nextQuickFavorite;
      _checkInitialization(generation);
      _database = database;
      published = true;
      _isClosed = false;
      _identityIndex.clear();
      counts = {};
      appdata.settings['followUpdatesFolder'] = trackingFolder;
      appdata.settings['quickFavorite'] = nextQuickFavorite;
      if (settingsChanged) await appdata.saveData(false);
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
    configuredFolder: () => appdata.settings['readLaterFolder'],
    selectFolder: (folder) => appdata.settings['readLaterFolder'] = folder,
    createFolder: (folder) {
      _createFolder(folder);
    },
    addFirst: (folder, comic) {
      _addComic(folder, comic, minValue(folder) - 1);
    },
    remove: (folder, id, type) {
      _deleteComicWithId(folder, id, type);
    },
    saveSettings: () => appdata.saveData(),
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
    return _mutate(
      () =>
          _readLater.set(captured, included: included, folderName: folderName),
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
    await _hashedIdsRefresh;
  }

  void refreshUpdateIds() => _updates.refresh();

  void _syncFollowUpdatesIfAffected(Iterable<String> folders) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !folders.contains(folder)) {
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
        throw "name is empty!";
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
      append: appdata.settings['newFavoriteAddTo'] == "end",
      order: order,
      updateTime: updateTime,
    );
    if (!added) return false;
    if (counts[folder] == null) {
      counts[folder] = count(folder);
    } else {
      counts[folder] = counts[folder]! + 1;
    }
    _refreshIdentityCounts([(comic.id, comic.type.value)]);
    _syncFollowUpdatesIfAffected([folder]);
    notifyListeners();
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

    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    _refreshIdentityCounts([(id, type.value)]);
    _syncFollowUpdatesIfAffected([sourceFolder, targetFolder]);
    notifyListeners();
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

    // Update counts
    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    _refreshIdentityCounts(items.map((item) => (item.id, item.type.value)));
    _syncFollowUpdatesIfAffected([sourceFolder, targetFolder]);

    notifyListeners();
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

    // Update counts
    counts[targetFolder] = count(targetFolder);
    _refreshIdentityCounts(items.map((item) => (item.id, item.type.value)));
    _syncFollowUpdatesIfAffected([targetFolder]);

    notifyListeners();
  }

  /// delete a folder
  Future<void> _deleteFolder(String name) async {
    var wasFollowUpdatesFolder =
        appdata.settings['followUpdatesFolder'] == name;
    final removedIdentities = _repository.identities(name);
    _repository.deleteFolder(name);
    counts.remove(name);
    var settingsChanged = false;
    for (final key in [
      'readLaterFolder',
      'quickFavorite',
      'followUpdatesFolder',
    ]) {
      if (appdata.settings[key] == name) {
        appdata.settings[key] = null;
        settingsChanged = true;
      }
    }
    _refreshIdentityCounts(removedIdentities);
    refreshUpdateIds();
    await _finishFolderMutation(settingsChanged, wasFollowUpdatesFolder);
  }

  /// SQL is already committed. Publish the resulting state even when saving
  /// its settings fails, and retain that outcome so callers cannot replay SQL.
  Future<void> _finishFolderMutation(
    bool saveSettings,
    bool followChanged, {
    PersistenceCommitState commitState = PersistenceCommitState.committed,
  }) async {
    final failures = <({Object error, StackTrace stackTrace})>[];
    if (saveSettings) {
      try {
        await appdata.saveData();
      } catch (error, stack) {
        failures.add((error: error, stackTrace: stack));
      }
    }
    if (followChanged) {
      try {
        _notifyFollowUpdatesChanged();
      } catch (error, stack) {
        failures.add((error: error, stackTrace: stack));
      }
    }
    notifyListeners();
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

  void _applyDeletedComics(Map<String, List<(String, int)>> removed) {
    if (removed.isEmpty) return;
    final identities = <(String, int)>{};
    for (final entry in removed.entries) {
      counts[entry.key] = count(entry.key);
      for (final (id, type) in entry.value) {
        identities.add((id, type));
      }
    }
    _refreshIdentityCounts(identities);
    // A cover is shared across folders. Files cannot participate in SQLite
    // rollback, so release them only after commit and the final reference.
    final folders = folderNames;
    for (final (id, type) in identities) {
      if (_repository.findFolders(folders, id, type).isNotEmpty) continue;
      try {
        deleteFavoriteCover(dataDirectory: App.dataPath, id: id, intKey: type);
      } catch (error, stack) {
        Log.error('Favorite cover cleanup', error, stack);
      }
    }
    _syncFollowUpdatesIfAffected(removed.keys);
    notifyListeners();
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
      removed = _repository.deleteComics([
        folder,
      ], comics.map((comic) => (comic.id, comic.type.value)));
    } catch (error) {
      Log.error('Batch Delete Comics', error.toString());
      rethrow;
    }
    _applyDeletedComics(removed);
  }

  Future<int> _removeInvalid() async {
    int count = 0;
    await Future.microtask(() {
      var all = allComics();
      for (var c in all) {
        var comicSource = c.type.comicSource;
        if ((c.type == ComicType.local &&
                LocalManager().find(c.id, c.type) == null) ||
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
    final previousTracking = appdata.settings['followUpdatesFolder'];
    final previousQuick = appdata.settings['quickFavorite'];
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
      try {
        await _closeAndWait();
        if (prepared) replacement!.restore();
        appdata.settings['followUpdatesFolder'] = previousTracking;
        appdata.settings['quickFavorite'] = previousQuick;
        await _startInitialization(path);
        await appdata.saveData(false);
      } catch (recoveryError, recoveryStack) {
        Log.error(
          'Clear favorites',
          'Recovery failed: $recoveryError. Original data is at $path or ${replacement?.backupFile.path}.',
          recoveryStack,
        );
      }
      // An unsuccessful restore must retain its backup for manual recovery.
      if (replacement == null || !replacement.backupFile.existsSync()) {
        _removeClearBackupDirectory(backupDirectory);
      }
      Error.throwWithStackTrace(error, stack);
    }
    try {
      replacement.commit();
      _removeClearBackupDirectory(backupDirectory);
    } catch (error, stack) {
      // Clearing succeeded; a cleanup failure must not roll back the new DB.
      Log.error(
        'Clear favorites',
        'Backup cleanup failed at ${replacement.backupFile.path}: $error',
        stack,
      );
    }
  }

  void _removeClearBackupDirectory(Directory? directory) {
    if (directory == null || !directory.existsSync()) return;
    try {
      directory.deleteSync();
    } catch (error, stack) {
      Log.error(
        'Clear favorites',
        'Could not remove backup directory ${directory.path}: $error',
        stack,
      );
    }
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
      throw "Name already exists!";
    }
    if (after.contains('"')) {
      throw "Invalid name";
    }
    var wasFollowUpdatesFolder =
        appdata.settings['followUpdatesFolder'] == before;
    _repository.renameFolder(before, after);
    counts[after] = counts[before] ?? 0;
    counts.remove(before);
    var settingsChanged = false;
    for (final key in [
      'readLaterFolder',
      'quickFavorite',
      'followUpdatesFolder',
    ]) {
      if (appdata.settings[key] == before) {
        appdata.settings[key] = after;
        settingsChanged = true;
      }
    }
    refreshUpdateIds();
    await _finishFolderMutation(settingsChanged, wasFollowUpdatesFolder);
  }

  void _onRead(String id, ComicType type) {
    if (appdata.settings['moveFavoriteAfterRead'] == "none") {
      _markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = appdata.settings['followUpdatesFolder'];
    final movement = appdata.settings['moveFavoriteAfterRead'];
    final changed = _repository.recordRead(
      folderNames.where((folder) => folder != readLaterFolder),
      id,
      type.value,
      time: DateTime.now()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .substring(0, 19),
      movement: movement is String ? movement : null,
      trackingFolder: followUpdatesFolder is String
          ? followUpdatesFolder
          : null,
    );
    if (changed.contains(followUpdatesFolder)) {
      _updates.recordCommittedRead(id, type.value);
      _notifyFollowUpdatesChanged();
    }
    notifyListeners();
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
    _repository.updateInfo(folder, comic);
    if (notify) {
      notifyListeners();
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
      append: appdata.settings['newFavoriteAddTo'] == 'end',
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
    counts[result.folder] = count(result.folder);
    _refreshIdentityCounts(result.identities);
    refreshUpdateIds();
    try {
      _syncFollowUpdatesIfAffected([result.folder]);
    } finally {
      // A follow-up observer must not prevent ordinary views from refreshing.
      notifyListeners();
    }
  });

  void _fromJson(String json) {
    final (folder, comics) = importFavoriteFolder(
      json,
      _repository,
      append: appdata.settings['newFavoriteAddTo'] == 'end',
      translateTags: _translateTags,
    );
    refreshImportedFavorites({folder: comics});
    notifyImportedFavorites([folder]);
  }

  void _prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    _repository.prepareForFollowUpdates(table, clearData: clearData);
    if (appdata.settings['followUpdatesFolder'] == table) {
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
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !existsFolder(folder)) {
      return;
    }
    _repository.markAsRead(folder, id, type.value);
    _updates.recordCommittedRead(id, type.value);
    if (notify) {
      _notifyFollowUpdatesChanged();
      notifyListeners();
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
