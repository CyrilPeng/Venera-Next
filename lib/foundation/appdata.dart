import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/log.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  Future<void> _writeQueue = Future.value();

  FutureOr<void> Function()? _syncDataRequestHandler;

  void registerSyncDataRequestHandler(FutureOr<void> Function()? handler) {
    _syncDataRequestHandler = handler;
  }

  Future<void> saveData([bool sync = true]) async {
    await _enqueueWrite(_writeAppData);
    final handler = _syncDataRequestHandler;
    if (sync && handler != null) {
      unawaited(Future.sync(handler));
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "webdavProxyEnabled",
    "backupWebdav",
    "backupWebdavPath",
    "webdavComicLibrary",
    "webdavComicLibraryPath",
    "disableSyncFields",
    "deviceId",
    "lastSyncTime",
  ];

  static const _archiveSyncFields = ["backupWebdav", "backupWebdavPath"];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data) {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"] as String,
      );

      final archiveSyncEnabled =
          this.settings["backupWebdavSyncEnabled"] == true;

      for (var key in settings.keys) {
        if (_archiveSyncFields.contains(key)) {
          if (archiveSyncEnabled) {
            this.settings[key] = settings[key];
          }
          continue;
        }
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }
    }
    searchHistory = List.from(data['searchHistory'] ?? []);
    saveData();
  }

  var implicitData = <String, dynamic>{};

  Future<void> _enqueueWrite(Future<void> Function() write) {
    var next = _writeQueue.then((_) => write(), onError: (_) => write());
    _writeQueue = next.catchError((Object error, StackTrace stackTrace) {
      Log.error("Appdata", error, stackTrace);
    });
    return next;
  }

  Future<void> _writeAppData() async {
    var futures = <Future>[];
    var json = toJson();
    var data = jsonEncode(json);
    var file = File(FilePath.join(App.dataPath, 'appdata.json'));
    futures.add(_writeTextAtomically(file, data));

    var disableSyncFields = json["settings"]["disableSyncFields"] as String;
    if (disableSyncFields.isNotEmpty) {
      var json4sync = jsonDecode(data);
      List<String> customDisableSync = splitField(disableSyncFields);
      for (var field in customDisableSync) {
        json4sync["settings"].remove(field);
      }
      var data4sync = jsonEncode(json4sync);
      var file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
      futures.add(_writeTextAtomically(file4sync, data4sync));
    }

    await Future.wait(futures);
  }

  void writeImplicitData() {
    unawaited(
      _enqueueWrite(() async {
        var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
        await _writeTextAtomically(file, jsonEncode(implicitData));
      }),
    );
  }

  @override
  Future<void> doInit() async {
    var dataPath = App.dataPath;
    await _loadAppData(dataPath);
    if ((settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    await _loadImplicitData(dataPath);
  }

  @visibleForTesting
  Future<void> loadDataForTesting(String dataPath) => _loadAppData(dataPath);

  Future<void> _loadAppData(String dataPath) async {
    final primary = File(FilePath.join(dataPath, 'appdata.json'));
    final candidates = [
      primary,
      File('${primary.path}.bak'),
      File(FilePath.join(dataPath, 'syncdata.json')),
    ];
    File? loadedFrom;
    var primaryInvalid = false;

    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      try {
        final decoded = _decodeAppData(await candidate.readAsString());
        for (final entry in decoded.settings.entries) {
          if (entry.value != null) {
            settings[entry.key] = entry.value;
          }
        }
        searchHistory = decoded.searchHistory;
        loadedFrom = candidate;
        break;
      } catch (error, stackTrace) {
        Log.error(
          "Appdata",
          "Failed to load ${candidate.path}",
          '$error\n$stackTrace',
        );
        if (candidate.path == primary.path) {
          primaryInvalid = true;
        }
      }
    }

    if (loadedFrom == null) {
      if (primaryInvalid) {
        await _preserveCorruptFile(primary);
      }
      return;
    }
    if (loadedFrom.path == primary.path) {
      return;
    }

    if (primaryInvalid) {
      await _preserveCorruptFile(primary);
    }
    await _writeTextAtomically(
      primary,
      await loadedFrom.readAsString(),
      createBackup: false,
    );
    Log.info("Appdata", "Recovered appdata from ${loadedFrom.path}");
  }

  ({Map<String, dynamic> settings, List<String> searchHistory}) _decodeAppData(
    String content,
  ) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('Appdata root must be an object');
    }
    final rawSettings = decoded['settings'];
    if (rawSettings is! Map) {
      throw const FormatException('Appdata settings must be an object');
    }
    final normalizedSettings = <String, dynamic>{};
    for (final entry in rawSettings.entries) {
      if (entry.key is String) {
        normalizedSettings[entry.key as String] = entry.value;
      }
    }

    final rawSearchHistory = decoded['searchHistory'];
    if (rawSearchHistory != null && rawSearchHistory is! List) {
      throw const FormatException('Appdata searchHistory must be a list');
    }
    return (
      settings: normalizedSettings,
      searchHistory: rawSearchHistory == null
          ? <String>[]
          : rawSearchHistory.whereType<String>().toList(),
    );
  }

  Future<void> _loadImplicitData(String dataPath) async {
    final primary = File(FilePath.join(dataPath, 'implicitData.json'));
    final candidates = [primary, File('${primary.path}.bak')];
    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Implicit data root must be an object');
        }
        implicitData = Map<String, dynamic>.from(decoded);
        if (candidate.path != primary.path) {
          await _preserveCorruptFile(primary);
          await _writeTextAtomically(
            primary,
            await candidate.readAsString(),
            createBackup: false,
          );
          Log.info("Appdata", "Recovered implicit data from ${candidate.path}");
        }
        return;
      } catch (error, stackTrace) {
        Log.error(
          "Appdata",
          "Failed to load ${candidate.path}",
          '$error\n$stackTrace',
        );
      }
    }
    if (await primary.exists()) {
      await _preserveCorruptFile(primary);
    }
  }

  Future<void> _writeTextAtomically(
    File target,
    String content, {
    bool createBackup = true,
  }) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(content, flush: true);

    try {
      if (createBackup && await target.exists()) {
        await target.copy('${target.path}.bak');
      }
      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        await target.deleteIgnoreError();
        await temporary.rename(target.path);
      }
    } finally {
      await temporary.deleteIgnoreError();
    }
  }

  Future<void> _preserveCorruptFile(File file) async {
    if (!await file.exists()) {
      return;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final destination = '${file.path}.corrupt-$timestamp';
    try {
      await file.rename(destination);
      Log.warning("Appdata", "Preserved invalid data as $destination");
    } catch (error, stackTrace) {
      Log.error("Appdata", "Failed to preserve ${file.path}", stackTrace);
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'favoritesDisplayMode': 'list', // list, gallery
    'favoritesGalleryColumns': 0, // 0 means automatic, 2-6 are fixed
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'searchShortcuts': [],
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'showUpdateStatusOnTile': true,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'waterfallTopToBottom', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'readerBrightnessEnabled': false,
    'readerBrightness': 50, // 20 - 100
    'eInkRefreshEnabled': false,
    'eInkRefreshDuration': 100, // milliseconds
    'eInkRefreshInterval': 1, // page changes
    'eInkRefreshStyle': 'black', // black, white, whiteThenBlack
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'historyRetentionDays': 0, // 0 means disabled
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': false,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    'webdavProxyEnabled': true,
    'backupWebdav': [], // empty means not configured
    'backupWebdavPath': '/venera_backup/',
    'backupWebdavSyncEnabled': false,
    'webdavComicLibrary': [], // empty means not configured
    'webdavComicLibraryPath': '/venera_comics/',
    'webdavComicLibraryAutoSync': true,
    'webdavComicLibrarySyncIntervalMinutes': 360,
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': "",
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'splitDualPage': false,
    'splitDualPageInvert': false,
    'bangumiAccessToken': '',
    'bangumiUsername': '',
    'bangumiAutoSyncEnabled': true,
    'bangumiBindings': <String, Map<String, dynamic>>{},
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setActiveReaderSetting(
    String? comicId,
    String? sourceKey,
    String key,
    dynamic value,
  ) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      setReaderSetting(comicId!, sourceKey!, key, value);
    } else if (isDeviceSpecificSettingsEnabled()) {
      setDeviceReaderSetting(key, value);
    } else {
      this[key] = value;
    }
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';
