import 'favorite_identity_index.dart';
import 'favorites_repository.dart';
import 'favorite_models.dart';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/favorites/local_favorite_image.dart';
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
  _followUpdatesChangeListener?.call();
}

class LocalFavoritesManager with ChangeNotifier {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  late Database _db;

  FavoritesRepository get _repository => FavoritesRepository(_db);

  late String _dbPath;

  late Map<String, int> counts;

  final _identityIndex = FavoriteIdentityIndex();

  var _updatedIds = <(String, int)>{};

  String? _updatedIdsFolder;

  Future<void>? _hashedIdsRefresh;

  bool _isClosed = false;

  int get totalComics {
    return _identityIndex.length;
  }

  int folderComics(String folder) {
    return counts[folder] ?? 0;
  }

  Future<void> init() async {
    _isClosed = false;
    _identityIndex.clear();
    counts = {};
    _dbPath = "${App.dataPath}/local_favorite.db";
    final databaseExisted = File(_dbPath).existsSync();
    _db = openSqliteDatabase(_dbPath);
    _repository.initializeMetadata();
    var folderNames = _repository.folderNames();
    final foldersToMigrate = List<String>.from(folderNames);
    folderNames = _ensureTrackingFolder(
      folderNames,
      createIfMissing: !databaseExisted,
    );
    _repository.migrateTranslatedTags(foldersToMigrate, _translateTags);
    if (App.isInitialized) {
      await appdata.ensureInit();
    }
    var settingsChanged = false;
    final configuredTrackingFolder = appdata.settings['followUpdatesFolder'];
    final trackingFolder =
        configuredTrackingFolder is String &&
            folderNames.contains(configuredTrackingFolder)
        ? configuredTrackingFolder
        : !databaseExisted && folderNames.contains(trackingFolderName)
        ? trackingFolderName
        : null;
    if (configuredTrackingFolder != trackingFolder) {
      appdata.settings['followUpdatesFolder'] = trackingFolder;
      settingsChanged = true;
    }
    if (trackingFolder != null) {
      prepareTableForFollowUpdates(trackingFolder, false);
    }
    final quickFavorite = appdata.settings['quickFavorite'];
    if (quickFavorite is! String || !folderNames.contains(quickFavorite)) {
      final fallbackQuickFavorite =
          !databaseExisted && folderNames.contains(trackingFolderName)
          ? trackingFolderName
          : null;
      if (quickFavorite != fallbackQuickFavorite) {
        appdata.settings['quickFavorite'] = fallbackQuickFavorite;
        settingsChanged = true;
      }
    }
    initCounts();
    if (settingsChanged) {
      await appdata.saveData(false);
    }
  }

  void initCounts() {
    for (var folder in folderNames) {
      counts[folder] = count(folder);
    }
    refreshUpdateIds();
    _refreshHashedIds(folderNames);
  }

  void refreshHashedIds() {
    _refreshHashedIds(folderNames);
  }

  static const String trackingFolderName = "追更";

  String? get readLaterFolder {
    final folder = appdata.settings['readLaterFolder'];
    return folder is String && existsFolder(folder) ? folder : null;
  }

  bool isInReadLater(String id, ComicType type) {
    final folder = readLaterFolder;
    return folder != null && comicExists(folder, id, type);
  }

  List<FavoriteItem> getReadLaterComics({int? limit}) {
    final folder = readLaterFolder;
    if (folder == null) return [];
    return _repository.getFolderComics(folder, limit: limit);
  }

  Future<void> setReadLater(
    FavoriteItem comic, {
    required bool included,
    required String folderName,
  }) async {
    var folder = readLaterFolder;
    if (included) {
      if (folder == null) {
        folder = folderName;
        var suffix = 2;
        while (existsFolder(folder!)) {
          folder = '$folderName (${suffix++})';
        }
        createFolder(folder);
        appdata.settings['readLaterFolder'] = folder;
      }
      addComic(folder, comic, minValue(folder) - 1);
    } else if (folder != null && comicExists(folder, comic.id, comic.type)) {
      deleteComicWithId(folder, comic.id, comic.type);
    }
    await appdata.saveData();
  }

  List<String> _ensureTrackingFolder(
    List<String> folderNames, {
    required bool createIfMissing,
  }) {
    if (createIfMissing && folderNames.isEmpty) {
      createFolder(trackingFolderName);
      return _repository.folderNames();
    }
    return folderNames;
  }

  void _refreshHashedIds(List<String> folders) {
    final generation = _identityIndex.beginRefresh();
    if (folders.isEmpty) {
      _identityIndex.completeRefresh(generation, {});
      _hashedIdsRefresh = Future.value();
      return;
    }
    late Future<void> refresh;
    refresh = _initHashedIds(folders, _dbPath).then(
      (value) {
        if (_isClosed || !identical(_hashedIdsRefresh, refresh)) {
          return;
        }
        if (_identityIndex.completeRefresh(generation, value)) {
          notifyListeners();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _identityIndex.failRefresh(generation);
        Log.error("LocalFavoritesManager", error, stackTrace);
      },
    );
    _hashedIdsRefresh = refresh;
  }

  @visibleForTesting
  Future<void> debugWaitForHashedIdsRefresh() async {
    await _hashedIdsRefresh;
  }

  void refreshUpdateIds() {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !existsFolder(folder)) {
      _updatedIds = {};
      _updatedIdsFolder = null;
      return;
    }
    _updatedIdsFolder = folder;
    _updatedIds = _repository.identities(folder, updatedOnly: true).toSet();
  }

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
      var db = openSqliteDatabase(dbPath);
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

  Future<List<String>> findWithModel(FavoriteItem item) async =>
      find(item.id, item.type);

  void updateOrder(List<String> folders) {
    _repository.updateOrder(folders);
    notifyListeners();
  }

  int count(String folderName) => _repository.count(folderName);

  List<String> get folderNames => _repository.folderNames();

  int maxValue(String folder) => _repository.maxValue(folder);

  int minValue(String folder) => _repository.minValue(folder);

  List<FavoriteItem> getFolderComics(String folder) =>
      _repository.getFolderComics(folder);

  static Future<List<FavoriteItem>> _getFolderComicsAsync(
    String folder,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        return FavoritesRepository(db).getFolderComics(folder);
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get the comics in the folder
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    return _getFolderComicsAsync(folder, _dbPath);
  }

  List<FavoriteItem> getAllComics() => _repository.getAllComics(folderNames);

  static Future<List<FavoriteItem>> _getAllComicsAsync(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        return FavoritesRepository(db).getAllComics(folders);
      } finally {
        db.dispose();
      }
    });
  }

  /// Start a new isolate to get all the comics
  Future<List<FavoriteItem>> getAllComicsAsync() {
    return _getAllComicsAsync(folderNames, _dbPath);
  }

  void addTagTo(String folder, String id, String tag) {
    _repository.addTagTo(folder, id, tag);
    notifyListeners();
  }

  List<FavoriteItemWithFolderInfo> allComics() =>
      _repository.allComics(folderNames);

  bool existsFolder(String name) {
    return folderNames.contains(name);
  }

  /// create a folder
  String createFolder(String name, [bool renameWhenInvalidName = false]) {
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

  void linkFolderToNetwork(
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
  bool addComic(
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

  void moveFavorite(
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

  void batchMoveFavorites(
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
      return;
    }

    // Update counts
    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    _refreshIdentityCounts(items.map((item) => (item.id, item.type.value)));
    _syncFollowUpdatesIfAffected([sourceFolder, targetFolder]);

    notifyListeners();
  }

  void batchCopyFavorites(
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
      return;
    }

    // Update counts
    counts[targetFolder] = count(targetFolder);
    _refreshIdentityCounts(items.map((item) => (item.id, item.type.value)));
    _syncFollowUpdatesIfAffected([targetFolder]);

    notifyListeners();
  }

  /// delete a folder
  void deleteFolder(String name) {
    var wasFollowUpdatesFolder =
        appdata.settings['followUpdatesFolder'] == name;
    final removedIdentities = _repository.identities(name);
    _repository.deleteFolder(name);
    counts.remove(name);
    for (final key in ['readLaterFolder', 'quickFavorite']) {
      if (appdata.settings[key] == name) {
        appdata.settings[key] = null;
        appdata.saveData();
      }
    }
    _refreshIdentityCounts(removedIdentities);
    refreshHashedIds();
    if (wasFollowUpdatesFolder) {
      appdata.settings['followUpdatesFolder'] = null;
      refreshUpdateIds();
      _notifyFollowUpdatesChanged();
      appdata.saveData();
    }
    notifyListeners();
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
        LocalFavoriteImageProvider.delete(id, type);
      } catch (error, stack) {
        Log.error('Favorite cover cleanup', error, stack);
      }
    }
    _syncFollowUpdatesIfAffected(removed.keys);
    notifyListeners();
  }

  void deleteComicWithId(String folder, String id, ComicType type) {
    _applyDeletedComics(_repository.deleteComics([folder], [(id, type.value)]));
  }

  void batchDeleteComics(String folder, List<FavoriteItem> comics) {
    if (comics.isEmpty) return;
    late Map<String, List<(String, int)>> removed;
    try {
      removed = _repository.deleteComics([
        folder,
      ], comics.map((comic) => (comic.id, comic.type.value)));
    } catch (error) {
      Log.error('Batch Delete Comics', error.toString());
      return;
    }
    _applyDeletedComics(removed);
  }

  void batchDeleteComicsInAllFolders(List<ComicID> comics) {
    if (comics.isEmpty) return;
    late Map<String, List<(String, int)>> removed;
    try {
      removed = _repository.deleteComics(
        folderNames,
        comics.map((comic) => (comic.id, comic.type.value)),
      );
    } catch (error) {
      Log.error('Batch Delete Comics in All Folders', error.toString());
      return;
    }
    _applyDeletedComics(removed);
  }

  Future<int> removeInvalid() async {
    int count = 0;
    await Future.microtask(() {
      var all = allComics();
      for (var c in all) {
        var comicSource = c.type.comicSource;
        if ((c.type == ComicType.local &&
                LocalManager().find(c.id, c.type) == null) ||
            (c.type != ComicType.local && comicSource == null)) {
          deleteComicWithId(c.folder, c.id, c.type);
          count++;
        }
      }
    });
    return count;
  }

  Future<void> clearAll() async {
    _db.dispose();
    File("${App.dataPath}/local_favorite.db").deleteSync();
    await init();
  }

  void reorder(List<FavoriteItem> newFolder, String folder) async {
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
      return;
    }
    notifyListeners();
  }

  void rename(String before, String after) {
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
    refreshHashedIds();
    for (final key in ['readLaterFolder', 'quickFavorite']) {
      if (appdata.settings[key] == before) {
        appdata.settings[key] = after;
        appdata.saveData();
      }
    }
    if (wasFollowUpdatesFolder) {
      appdata.settings['followUpdatesFolder'] = after;
      refreshUpdateIds();
      _notifyFollowUpdatesChanged();
      appdata.saveData();
    }
    notifyListeners();
  }

  void onRead(String id, ComicType type) {
    if (appdata.settings['moveFavoriteAfterRead'] == "none") {
      markAsRead(id, type);
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
      _updatedIds.remove((id, type.value));
      _notifyFollowUpdatesChanged();
    }
    notifyListeners();
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) =>
      _repository.searchInFolder(folder, keyword);

  List<FavoriteItem> search(String keyword) =>
      _repository.search(folderNames, keyword);

  void editTags(String id, String folder, List<String> tags) {
    _repository.editTags(folder, id, tags);
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    return _identityIndex.contains(id, type.value);
  }

  bool hasNewUpdate(String id, ComicType type) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || folder != _updatedIdsFolder) {
      return false;
    }
    return _updatedIds.contains((id, type.value));
  }

  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
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

  void fromJson(String json) {
    var data = jsonDecode(json);
    var folder = data["name"];
    if (folder == null || folder is! String) {
      throw "Invalid data";
    }
    if (existsFolder(folder)) {
      int i = 0;
      while (existsFolder("$folder($i)")) {
        i++;
      }
      folder = "$folder($i)";
    }
    createFolder(folder);
    for (var comic in data["comics"]) {
      try {
        addComic(folder, FavoriteItem.fromJson(comic));
      } catch (e) {
        Log.error("Import Data", e.toString());
      }
    }
  }

  void prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    _repository.prepareForFollowUpdates(table, clearData: clearData);
    if (appdata.settings['followUpdatesFolder'] == table) {
      refreshUpdateIds();
    }
  }

  void updateUpdateTime(
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
    if (appdata.settings['followUpdatesFolder'] == folder) {
      _updatedIdsFolder = folder;
      final identity = (id, type.value);
      if (hasNewUpdate) {
        _updatedIds.add(identity);
      } else {
        _updatedIds.remove(identity);
      }
    }
  }

  void updateCheckTime(String folder, String id, ComicType type) =>
      _repository.updateCheckTime(
        folder,
        id,
        type.value,
        DateTime.now().millisecondsSinceEpoch,
      );

  int countUpdates(String folder) => _repository.countUpdates(folder);

  List<FavoriteItemWithUpdateInfo> getUpdates(String folder) =>
      existsFolder(folder)
      ? _repository.getComicsWithUpdatesInfo(folder, updatedOnly: true)
      : [];

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) =>
      existsFolder(folder) ? _repository.getComicsWithUpdatesInfo(folder) : [];

  void markAsRead(String id, ComicType type, {bool notify = true}) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !existsFolder(folder)) {
      return;
    }
    _repository.markAsRead(folder, id, type.value);
    _updatedIds.remove((id, type.value));
    if (notify) {
      _notifyFollowUpdatesChanged();
      notifyListeners();
    }
  }

  void close() {
    _isClosed = true;
    _identityIndex.clear();
    _updatedIds.clear();
    _updatedIdsFolder = null;
    counts.clear();
    _db.dispose();
  }

  void notifyChanges() {
    refreshUpdateIds();
    notifyListeners();
  }
}
