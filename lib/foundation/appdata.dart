import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/app_data_sync_fields.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/reader_settings.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/reader_preference_settings.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/log.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  Future<void>? _writeQueue;

  FutureOr<void> Function()? _syncDataRequestHandler;

  void registerSyncDataRequestHandler(FutureOr<void> Function()? handler) {
    _syncDataRequestHandler = handler;
  }

  /// Legacy save entry. New edits must use [updateSettings] so memory changes
  /// happen after admission as well. The path is fixed at admission; capture
  /// the contents after earlier edits have finished, not ahead of the queue.
  Future<void> saveData([bool sync = true]) =>
      AppDataOperations.instance.access(() {
        final path = App.dataPath;
        return _enqueueWrite(() async {
          await _writeAppData(path, _appDataContents(jsonEncode(toJson())));
          _requestSync(sync);
        });
      });

  /// Edit an isolated draft inside admitted, serialized work, then await its
  /// persistence. The callback must be synchronous and use the supplied draft;
  /// callers capture mutable inputs before submitting. Retained draft references
  /// cannot change the published settings after the callback returns.
  Future<T> updateSettings<T>(
    T Function(Settings settings) change, {
    bool sync = true,
    Object? Function(Map<String, String> contents)? beforePersist,
    // Initialization repairs can avoid rewriting an unchanged snapshot. Normal
    // saves keep this true so retrying an already-published value writes again.
    bool persistIfUnchanged = true,
  }) => _edit(
    (draft, _) {
      final previousExclusions = jsonEncode(draft['disableSyncFields']);
      final result = change(draft);
      _requireSynchronousEdit(result);
      final exclusions = draft['disableSyncFields'];
      // Preserve malformed legacy values during unrelated edits, but never
      // accept a newly malformed filter from an explicit settings mutation.
      if (exclusions is! String &&
          jsonEncode(exclusions) != previousExclusions) {
        throw const FormatException('Sync exclusions must be a string');
      }
      return result;
    },
    sync: sync,
    beforePersist: beforePersist,
    persistIfUnchanged: persistIfUnchanged,
  );

  /// Serialize storage recovery with settings writers. The callback receives
  /// the admitted directory and must not re-enter an Appdata writer.
  Future<void> runPersistenceMaintenance(
    Future<void> Function(String) action,
  ) => AppDataOperations.instance.access(() {
    final path = App.dataPath;
    return _enqueueWrite(() => action(path));
  });

  /// Restore only an operation's captured fields, preserving unrelated values.
  /// A recovery owner using persist:false must subsequently finish durability.
  Future<void> restoreSettingsFields(
    Map<String, dynamic> fields, {
    bool persist = true,
  }) {
    final snapshot = jsonEncode(fields);
    return _edit(
      (draft, _) {
        final values = jsonDecode(snapshot) as Map<String, dynamic>;
        for (final entry in values.entries) {
          draft[entry.key] = entry.value;
        }
      },
      sync: false,
      persist: persist,
    );
  }

  Future<T> _edit<T>(
    T Function(Settings, List<String>) change, {
    required bool sync,
    bool persist = true,
    bool persistIfUnchanged = true,
    Object? Function(Map<String, String> contents)? beforePersist,
  }) => AppDataOperations.instance.access(() {
    final path = App.dataPath;
    return _enqueueWrite(() async {
      final before = jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>;
      final draft = Settings._create().._batchDepth = 1;
      draft._data
        ..clear()
        ..addAll(
          jsonDecode(jsonEncode(before['settings'])) as Map<String, dynamic>,
        );
      final history = List<String>.from(before['searchHistory'] as List);
      final result = change(draft, history);
      _requireSynchronousEdit(result);
      final snapshot = jsonEncode({
        'settings': draft._data,
        'searchHistory': history,
      });
      final contents = _appDataContents(snapshot);
      if (beforePersist != null) {
        _requireSynchronousEdit(beforePersist(Map.unmodifiable(contents)));
      }
      final published = jsonDecode(snapshot) as Map<String, dynamic>;
      final settingsChanged = _applyChangedFields(
        settings._data,
        before['settings'] as Map<String, dynamic>,
        published['settings'] as Map<String, dynamic>,
      );
      final historyChanged = !listEquals(
        before['searchHistory'] as List,
        published['searchHistory'] as List,
      );
      if (historyChanged) {
        searchHistory = List<String>.from(published['searchHistory'] as List);
      }
      // Persistence can partially commit. Keep the applied memory state and
      // report the real failure rather than restoring an unrelated snapshot.
      try {
        if (persist &&
            (persistIfUnchanged || settingsChanged || historyChanged)) {
          await _writeAppData(path, contents);
        }
      } finally {
        if (settingsChanged || draft._notificationPending) {
          settings.notifyListeners();
        }
      }
      _requestSync(sync);
      return result;
    });
  });

  // Preserve unchanged legacy collection references until their writers have
  // migrated too. Publishing an unrelated edit must not detach those values.
  bool _applyChangedFields(
    Map<String, dynamic> target,
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    var changed = false;
    for (final key in before.keys) {
      if (!after.containsKey(key)) {
        target.remove(key);
        changed = true;
      }
    }
    for (final entry in after.entries) {
      if (!before.containsKey(entry.key) ||
          jsonEncode(before[entry.key]) != jsonEncode(entry.value)) {
        target[entry.key] = entry.value;
        changed = true;
      }
    }
    return changed;
  }

  void _requireSynchronousEdit(Object? result) {
    if (result is! Future) return;
    // An accidental async callback may already be running. Its draft stays
    // detached, and its eventual error must not become an unhandled error.
    unawaited(
      result.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          Log.error('Appdata', error, stack);
        },
      ),
    );
    throw ArgumentError('Appdata edit callbacks must be synchronous');
  }

  void _requestSync(bool sync) {
    final handler = _syncDataRequestHandler;
    if (sync && handler != null) {
      AppDataOperations.instance.publish(() => unawaited(Future.sync(handler)));
    }
  }

  Future<void> addSearchHistory(String keyword) => _edit((_, history) {
    if (history.contains(keyword)) {
      history.remove(keyword);
    }
    history.insert(0, keyword);
    if (history.length > 50) {
      history.removeLast();
    }
  }, sync: true);

  Future<void> removeSearchHistory(String keyword) => _edit((_, history) {
    history.remove(keyword);
  }, sync: true);

  Future<void> clearSearchHistory() => _edit((_, history) {
    history.clear();
  }, sync: true);

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) => splitAppDataFields(merged);

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = appDataLocalFields;

  static const _archiveSyncFields = appDataOptionalArchiveFields;

  /// Apply imported data and acknowledge its actual persistence. Importing a
  /// remote snapshot must not announce the same data as a new local edit.
  Future<void> syncData(Map<String, dynamic> data) {
    final snapshot = jsonEncode(data);
    return _edit((draft, history) {
      final data = jsonDecode(snapshot) as Map<String, dynamic>;
      if (data['settings'] is Map) {
        var settings = data['settings'] as Map<String, dynamic>;

        List<String> customDisableSync = splitField(
          SyncConfiguration.readExcludedFields(draft['disableSyncFields']),
        );

        final archiveSyncEnabled = draft["backupWebdavSyncEnabled"] == true;

        for (var key in settings.keys) {
          if (_archiveSyncFields.contains(key)) {
            if (archiveSyncEnabled) {
              draft[key] = settings[key];
            }
            continue;
          }
          if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
            draft[key] = settings[key];
          }
        }
      }
      history
        ..clear()
        ..addAll(List<String>.from(data['searchHistory'] ?? []));
    }, sync: false);
  }

  AppdataImportCheckpoint captureImportCheckpoint() =>
      AppdataImportCheckpoint._(jsonEncode(toJson()));

  /// Restore every imported setting, including removal of newly introduced
  /// keys, before acknowledging that an archive rollback has completed.
  Future<void> restoreImportCheckpoint(
    AppdataImportCheckpoint checkpoint, {
    bool persist = true,
  }) => _edit(
    (draft, history) {
      final data = jsonDecode(checkpoint.json) as Map<String, dynamic>;
      history
        ..clear()
        ..addAll(List<String>.from(data['searchHistory'] as List));
      draft._restoreImportData(data['settings'] as Map<String, dynamic>);
    },
    sync: false,
    persist: persist,
  );

  var implicitData = <String, dynamic>{};

  Future<T> _enqueueWrite<T>(Future<T> Function() write) {
    final previous = _writeQueue;
    final completed = Completer<void>();
    // Register before calling user code, including when the queue is idle.
    // Drop an idle tail so later work does not retain its old caller's Zone.
    _writeQueue = completed.future;
    final next = previous == null
        ? Future<T>.sync(write)
        : previous.then((_) => write());
    void finish() {
      if (identical(_writeQueue, completed.future)) _writeQueue = null;
      completed.complete();
    }

    unawaited(
      next.then<void>(
        (_) => finish(),
        onError: (Object error, StackTrace stack) {
          try {
            Log.error('Appdata', error, stack);
          } finally {
            finish();
          }
        },
      ),
    );
    return next;
  }

  Map<String, String> _appDataContents(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    final contents = {'appdata.json': data};
    final disableSyncFields = SyncConfiguration.readExcludedFields(
      json['settings']['disableSyncFields'],
    );
    if (disableSyncFields.isNotEmpty) {
      for (final field in splitField(disableSyncFields)) {
        json['settings'].remove(field);
      }
      contents['syncdata.json'] = jsonEncode(json);
    }
    return contents;
  }

  Future<void> _writeAppData(String path, Map<String, String> contents) async {
    final futures = <Future<void>>[];
    final failures = <AppdataWriteDiagnostic>[];
    Future<void> write(File file, String content) async {
      try {
        await _writeTextAtomically(file, content);
      } catch (error, stack) {
        failures.add((path: file.path, error: error, stack: stack));
      }
    }

    for (final entry in contents.entries) {
      futures.add(write(File(FilePath.join(path, entry.key)), entry.value));
    }

    await Future.wait(futures);
    if (failures.length == 1) {
      Error.throwWithStackTrace(failures.single.error, failures.single.stack);
    }
    if (failures.isNotEmpty) throw AppdataWriteFailure(failures);
  }

  Future<void> writeImplicitData() => AppDataOperations.instance.access(() {
    final file = File(FilePath.join(App.dataPath, 'implicitData.json'));
    return _enqueueWrite(
      () => _writeTextAtomically(file, jsonEncode(implicitData)),
    );
  });

  Future<T> updateImplicit<T>(T Function(Map<String, dynamic> data) change) =>
      AppDataOperations.instance.access(() {
        final file = File(FilePath.join(App.dataPath, 'implicitData.json'));
        return _enqueueWrite(() async {
          final before =
              jsonDecode(jsonEncode(implicitData)) as Map<String, dynamic>;
          final draft = jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
          final result = change(draft);
          _requireSynchronousEdit(result);
          final snapshot = jsonEncode(draft);
          _applyChangedFields(
            implicitData,
            before,
            jsonDecode(snapshot) as Map<String, dynamic>,
          );
          await _writeTextAtomically(file, snapshot);
          return result;
        });
      });

  @override
  Future<void> init() => AppDataOperations.instance.access(super.init);

  @override
  Future<void> retryInit() =>
      AppDataOperations.instance.access(super.retryInit);

  @override
  Future<void> doInit() {
    var dataPath = App.dataPath;
    return _enqueueWrite(() async {
      await _loadAppData(dataPath);
      final deviceId = settings['deviceId'];
      if (deviceId is! String || deviceId.isEmpty) {
        settings._data["deviceId"] = const Uuid().v4();
        await _writeAppData(dataPath, _appDataContents(jsonEncode(toJson())));
      }
      await _loadImplicitData(dataPath);
    });
  }

  @visibleForTesting
  Future<void> loadDataForTesting(String dataPath) => AppDataOperations.instance
      .access(() => _enqueueWrite(() => _loadAppData(dataPath)));

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

/// Immutable recovery image owned by one application-data import.
class AppdataImportCheckpoint {
  const AppdataImportCheckpoint._(this.json);
  final String json;
}

typedef AppdataWriteDiagnostic = ({
  String path,
  Object error,
  StackTrace stack,
});

/// Both metadata files have finished, and each failed write remains observable.
class AppdataWriteFailure implements Exception {
  AppdataWriteFailure(Iterable<AppdataWriteDiagnostic> failures)
    : failures = List.unmodifiable(failures);
  final List<AppdataWriteDiagnostic> failures;

  @override
  String toString() =>
      failures.map((failure) => '${failure.path}: ${failure.error}').join('; ');
}

final appdata = Appdata._create();

class Settings with ChangeNotifier implements ReaderPreferenceSettings {
  int _batchDepth = 0;
  bool _notificationPending = false;
  @override
  void notifyListeners() {
    if (_batchDepth > 0) {
      _notificationPending = true;
    } else {
      AppDataOperations.instance.publish(super.notifyListeners);
    }
  }

  void _restoreImportData(Map<String, dynamic> values) {
    _data
      ..clear()
      ..addAll(values);
    notifyListeners();
  }

  Settings._create();

  final _data = <String, dynamic>{
    ...ReaderPreferences.storageDefaults,
    ...applicationPreferenceDefaults,
    'searchShortcuts': [],
    'comicLayoutDetections': <String, dynamic>{},
    'enableLongPressToZoom': true,
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
    'comicSourceListUrl': "",
    'comicSourceRepositories': <Map<String, dynamic>>[],
    'comicSourceOrigins': <String, dynamic>{},
    'comicSourceRepositoriesMigrated': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
  };

  /// Legacy heterogeneous settings bridge; typed consumers use preference snapshots.
  @override
  dynamic operator [](String key) {
    if (key == 'longPressAction') return _longPressAction(_data) ?? 'zoom';
    return _data[key];
  }

  @override
  void operator []=(String key, dynamic value) {
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
    // Freeze the legacy mode's current meaning before changing the switch for
    // other options. Toggling brightness/gesture overrides must not change mode.
    final values = _scopeRecord('comicSpecificSettings', '$comicId@$sourceKey');
    if (values is Map &&
        values.containsKey('readerMode') &&
        !values.containsKey('readerModeOverride')) {
      setComicReaderModeOverride(
        comicId,
        sourceKey,
        comicReaderModeOverride(comicId, sourceKey),
      );
    }
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _scopeRecord(
          'comicSpecificSettings',
          '$comicId@$sourceKey',
        )?['enabled'] ==
        true;
  }

  ReaderSettings get globalReaderSettings =>
      ReaderSettings.resolve(global: _data);

  /// Resolve an immutable snapshot without changing stored settings or scopes.
  ReaderSettings readerSettings(String comicId, String sourceKey) {
    Map? record(Object? container, String key) {
      final value = container is Map ? container[key] : null;
      return value is Map ? value : null;
    }

    final deviceId = _data['deviceId'];
    return ReaderSettings.resolve(
      global: _data,
      device: deviceId is String && deviceId.isNotEmpty
          ? record(_data['deviceSpecificSettings'], deviceId)
          : null,
      comic: record(_data['comicSpecificSettings'], '$comicId@$sourceKey'),
      layout: comicLayout(comicId, sourceKey),
    );
  }

  @override
  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (key == 'readerMode') return resolveReaderMode(comicId, sourceKey);
    if (key == 'longPressAction' &&
        isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      final action = _longPressAction(
        _scopeRecord('comicSpecificSettings', '$comicId@$sourceKey'),
      );
      return action ?? getDeviceReaderSetting(key);
    }
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue = _scopeRecord(
        'comicSpecificSettings',
        '$comicId@$sourceKey',
      )?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  /// A mode override is independent of the switch for other comic settings.
  /// Legacy per-comic modes remain effective until explicitly changed.
  String? comicReaderModeOverride(String comicId, String sourceKey) {
    final values = _scopeRecord('comicSpecificSettings', '$comicId@$sourceKey');
    if (values is! Map) return null;
    if (values.containsKey('readerModeOverride')) {
      final mode = values['readerModeOverride'];
      return mode is String && mode != 'default' ? mode : null;
    }
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      final mode = values['readerMode'];
      return mode is String ? mode : null;
    }
    return null;
  }

  void setComicReaderModeOverride(
    String comicId,
    String sourceKey,
    String? mode,
  ) {
    setReaderSetting(
      comicId,
      sourceKey,
      'readerModeOverride',
      mode ?? 'default',
    );
  }

  ComicLayout comicLayout(String comicId, String sourceKey) {
    final record = _scopeRecord('comicLayoutDetections', '$comicId@$sourceKey');
    if (record is! Map || record['version'] != ComicLayoutDetection.version) {
      return ComicLayout.unknown;
    }
    return ComicLayout.fromKey(record['layout']);
  }

  void setComicLayout(
    String comicId,
    String sourceKey,
    ComicLayoutDetection detection,
  ) {
    final records = _copyScopeContainer('comicLayoutDetections');
    records['$comicId@$sourceKey'] = {
      'layout': detection.layout.name,
      'samples': detection.sampleCount,
      'version': ComicLayoutDetection.version,
    };
    _data['comicLayoutDetections'] = records;
    notifyListeners();
  }

  String resolveReaderMode(String comicId, String sourceKey) =>
      readerSettings(comicId, sourceKey).readerMode;

  @override
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

  @override
  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    _writeScopeValue(
      'comicSpecificSettings',
      '$comicId@$sourceKey',
      key,
      value,
    );
  }

  void resetComicReaderSettings(String key) {
    final records = _copyScopeContainer('comicSpecificSettings')..remove(key);
    _data['comicSpecificSettings'] = records;
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    final deviceId = _data['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      return false;
    }
    return _scopeRecord('deviceSpecificSettings', deviceId)?['enabled'] == true;
  }

  static String? _longPressAction(dynamic values) {
    if (values is! Map) return null;
    final action = values['longPressAction'];
    if (const ['zoom', 'autoReading', 'none'].contains(action)) return action;
    final legacy = values['enableLongPressToZoom'];
    return legacy is bool ? (legacy ? 'zoom' : 'none') : null;
  }

  @override
  dynamic getDeviceReaderSetting(String key) {
    if (key == 'longPressAction') {
      if (isDeviceSpecificSettingsEnabled()) {
        final action = _longPressAction(
          _scopeRecord('deviceSpecificSettings', _data['deviceId'] as String),
        );
        if (action != null) return action;
      }
      return this[key];
    }
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _scopeRecord('deviceSpecificSettings', deviceId)?[key] ?? _data[key];
  }

  @override
  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    _writeScopeValue('deviceSpecificSettings', deviceId, key, value);
  }

  void resetDeviceReaderSettings() {
    final deviceId = _data['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      return;
    }
    final records = _copyScopeContainer('deviceSpecificSettings')
      ..remove(deviceId);
    _data['deviceSpecificSettings'] = records;
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    final deviceId = _data['deviceId'];
    if (deviceId is String && deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  Map? _scopeRecord(String container, String identity) {
    final records = _data[container];
    final record = records is Map ? records[identity] : null;
    return record is Map ? record : null;
  }

  Map<String, dynamic> _copyScopeContainer(String container) =>
      _copyStringKeys(_data[container]);

  static Map<String, dynamic> _copyStringKeys(Object? value) => {
    if (value is Map)
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
  };

  /// Explicit edits repair only their selected record. Reads never normalize
  /// storage, and unrelated or future records survive an edit and JSON export.
  void _writeScopeValue(
    String container,
    String identity,
    String key,
    Object? value,
  ) {
    final records = _copyScopeContainer(container);
    records[identity] = _copyStringKeys(records[identity])..[key] = value;
    _data[container] = records;
    notifyListeners();
  }

  @override
  String toString() {
    return _data.toString();
  }
}
