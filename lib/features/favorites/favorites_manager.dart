import 'favorites_repository.dart';
import 'favorite_models.dart';
import 'favorite_row.dart';
import 'dart:collection';
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

  var _hashedIds = <int, int>{};

  var _updatedIds = <int>{};

  String? _updatedIdsFolder;

  Future<void>? _hashedIdsRefresh;

  bool _isClosed = false;

  int get totalComics {
    return _hashedIds.length;
  }

  int folderComics(String folder) {
    return counts[folder] ?? 0;
  }

  Future<void> init() async {
    _isClosed = false;
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
    if (folders.isEmpty) {
      _hashedIds = {};
      _hashedIdsRefresh = Future.value();
      return;
    }
    late Future<void> refresh;
    refresh = _initHashedIds(folders, _dbPath).then(
      (value) {
        if (_isClosed || !identical(_hashedIdsRefresh, refresh)) {
          return;
        }
        _hashedIds = value;
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
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
    var rows = _db.select("""
      select id, type from "$folder"
      where has_new_update == 1;
    """);
    _updatedIdsFolder = folder;
    _updatedIds = rows
        .map((row) => (row["id"] as String).hashCode ^ (row["type"] as int))
        .toSet();
  }

  void _syncFollowUpdatesIfAffected(Iterable<String> folders) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !folders.contains(folder)) {
      return;
    }
    refreshUpdateIds();
    _notifyFollowUpdatesChanged();
  }

  void reduceHashedId(String id, int type) {
    var hash = id.hashCode ^ type;
    if (_hashedIds.containsKey(hash)) {
      if (_hashedIds[hash]! > 1) {
        _hashedIds[hash] = _hashedIds[hash]! - 1;
      } else {
        _hashedIds.remove(hash);
      }
    }
  }

  static Future<Map<int, int>> _initHashedIds(
    List<String> folders,
    String dbPath,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        var hashedIds = <int, int>{};
        for (var folder in folders) {
          var rows = db.select("""
            select id, type from "$folder";
          """);
          for (var row in rows) {
            var id = row["id"] as String;
            var type = row["type"] as int;
            var hash = id.hashCode ^ type;
            hashedIds[hash] = (hashedIds[hash] ?? 0) + 1;
          }
        }
        return hashedIds;
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
    var hash = comic.id.hashCode ^ comic.type.value;
    _hashedIds[hash] = (_hashedIds[hash] ?? 0) + 1;
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
    refreshHashedIds();
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
    refreshHashedIds();
    _syncFollowUpdatesIfAffected([targetFolder]);

    notifyListeners();
  }

  /// delete a folder
  void deleteFolder(String name) {
    var wasFollowUpdatesFolder =
        appdata.settings['followUpdatesFolder'] == name;
    _repository.deleteFolder(name);
    counts.remove(name);
    for (final key in ['readLaterFolder', 'quickFavorite']) {
      if (appdata.settings[key] == name) {
        appdata.settings[key] = null;
        appdata.saveData();
      }
    }
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
        reduceHashedId(id, type);
        identities.add((id, type));
      }
    }
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

  void onRead(String id, ComicType type) async {
    if (appdata.settings['moveFavoriteAfterRead'] == "none") {
      markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = appdata.settings['followUpdatesFolder'];
    for (final folder in folderNames) {
      if (folder == readLaterFolder) continue;
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        var newTime = DateTime.now()
            .toIso8601String()
            .replaceFirst("T", " ")
            .substring(0, 19);
        String updateLocationSql = "";
        if (appdata.settings['moveFavoriteAfterRead'] == "end") {
          int maxValue =
              _db.select("""
            SELECT MAX(display_order) AS max_value
            FROM "$folder";
          """).firstOrNull?["max_value"] ??
              0;
          updateLocationSql = "display_order = ${maxValue + 1},";
        } else if (appdata.settings['moveFavoriteAfterRead'] == "start") {
          int minValue =
              _db.select("""
            SELECT MIN(display_order) AS min_value
            FROM "$folder";
          """).firstOrNull?["min_value"] ??
              0;
          updateLocationSql = "display_order = ${minValue - 1},";
        }
        _db.execute(
          """
            UPDATE "$folder"
            SET 
              $updateLocationSql
              ${followUpdatesFolder == folder ? "has_new_update = 0," : ""}
              time = ?
            WHERE id == ? and type == ?;
          """,
          [newTime, id, type.value],
        );
        if (followUpdatesFolder == folder) {
          _updatedIds.remove(id.hashCode ^ type.value);
          _notifyFollowUpdatesChanged();
        }
      }
    }
    notifyListeners();
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) =>
      _repository.searchInFolder(folder, keyword);

  List<FavoriteItem> search(String keyword) =>
      _repository.search(folderNames, keyword);

  void editTags(String id, String folder, List<String> tags) {
    _db.execute(
      """
        update "$folder"
        set tags = ?
        where id == ?;
      """,
      [tags.join(","), id],
    );
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    var hash = id.hashCode ^ type.value;
    return _hashedIds.containsKey(hash);
  }

  bool hasNewUpdate(String id, ComicType type) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || folder != _updatedIdsFolder) {
      return false;
    }
    return _updatedIds.contains(id.hashCode ^ type.value);
  }

  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
    _repository.updateInfo(folder, comic);
    if (notify) {
      notifyListeners();
    }
  }

  String folderToJson(String folder) {
    var res = _db.select("""
      select * from "$folder";
    """);
    return jsonEncode({
      "info": "Generated by VeneraNext",
      "name": folder,
      "comics": res.map((e) => favoriteItemFromRow(e).toJson()).toList(),
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
    var oldTime = _db
        .select(
          """
      select last_update_time from "$folder"
      where id == ? and type == ?;
    """,
          [id, type.value],
        )
        .first['last_update_time'];
    var hasNewUpdate = oldTime != updateTime;
    _db.execute(
      """
      update "$folder"
      set last_update_time = ?, has_new_update = ?, last_check_time = ?
      where id == ? and type == ?;
    """,
      [
        updateTime,
        hasNewUpdate ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
        id,
        type.value,
      ],
    );
    if (appdata.settings['followUpdatesFolder'] == folder) {
      _updatedIdsFolder = folder;
      var hash = id.hashCode ^ type.value;
      if (hasNewUpdate) {
        _updatedIds.add(hash);
      } else {
        _updatedIds.remove(hash);
      }
    }
  }

  void updateCheckTime(String folder, String id, ComicType type) {
    _db.execute(
      """
      update "$folder"
      set last_check_time = ?
      where id == ? and type == ?;
    """,
      [DateTime.now().millisecondsSinceEpoch, id, type.value],
    );
  }

  int countUpdates(String folder) {
    return _db.select("""
      select count(*) as c from "$folder"
      where has_new_update == 1;
    """).first['c'];
  }

  List<FavoriteItemWithUpdateInfo> getUpdates(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from "$folder"
      where has_new_update == 1;
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            favoriteItemFromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from "$folder";
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            favoriteItemFromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  void markAsRead(String id, ComicType type, {bool notify = true}) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String || !existsFolder(folder)) {
      return;
    }
    _db.execute(
      """
      update "$folder"
      set has_new_update = 0
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    _updatedIds.remove(id.hashCode ^ type.value);
    if (notify) {
      _notifyFollowUpdatesChanged();
      notifyListeners();
    }
  }

  void close() {
    _isClosed = true;
    _db.dispose();
  }

  void notifyChanges() {
    refreshUpdateIds();
    notifyListeners();
  }
}
