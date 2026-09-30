import 'dart:async';

import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/file_system.dart';

export 'package:venera_next/foundation/sync_configuration.dart'
    show DataSyncMode;

enum _DataSyncTask { upload, download }

final _syncPreferences = SyncPreferenceStore(appdata);

class DataSyncStatusSnapshot {
  const DataSyncStatusSnapshot({
    this.isConfigured = false,
    required this.isEnabled,
    required this.isUploading,
    required this.isDownloading,
    required this.lastSyncTime,
    required this.lastError,
  });

  final bool isEnabled;
  final bool isConfigured;
  final bool isUploading;
  final bool isDownloading;
  final int lastSyncTime;
  final String? lastError;

  bool get isSyncing => isUploading || isDownloading;

  bool get shouldShow => isConfigured || isEnabled || isSyncing;

  String get title => isSyncing ? 'Syncing Data' : 'Sync Data';

  String get formattedLastSyncTime => _formatTime(lastSyncTime);

  static String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class DataSync with ChangeNotifier {
  DataSync._();

  bool _started = false;

  /// Attach automatic synchronization once, after core services are ready.
  void start() {
    if (_disposed) throw StateError('Cannot start a disposed DataSync');
    if (_started) return;
    _started = true;
    appdata.registerSyncDataRequestHandler(onDataChanged);
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    checkForAutomaticSync(startup: true);
  }

  void onDataChanged() {
    // Import notifications describe the downloaded snapshot, not local edits.
    if (_disposed || _isDownloading || !hasConfiguration) return;
    _changeGeneration++;
    if (!hasPendingChanges) {
      _syncPreferences.pending = true;
      appdata.writeImplicitData();
    }
    if (_started &&
        isEnabled &&
        mode == DataSyncMode.realtime &&
        !_configuring) {
      unawaited(uploadData());
    }
  }

  static DataSyncMode get mode => _syncPreferences.configuration.mode;

  static const intervalOptions = SyncConfiguration.intervalOptions;

  static int get intervalMinutes =>
      _syncPreferences.configuration.intervalMinutes;

  bool get hasConfiguration => _validateConfig()?.isValid == true;

  bool get hasPendingChanges => _syncPreferences.pending;

  Timer? _scheduleTimer;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  DateTime? _lastRealtimeCheck;

  @visibleForTesting
  static DateTime Function()? debugNow;

  DateTime get _now => debugNow?.call() ?? DateTime.now();

  /// Called at startup and resume, independently of the home page being mounted.
  /// Timers only run in this process; overdue checks are caught up on next launch.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (!_started ||
        _disposed ||
        _configuring ||
        !isEnabled ||
        _activeTask != null) {
      return;
    }
    if (mode == DataSyncMode.realtime) {
      if (!startup &&
          _lastRealtimeCheck != null &&
          _now.difference(_lastRealtimeCheck!) < const Duration(minutes: 10)) {
        return;
      }
      _lastRealtimeCheck = _now;
    } else {
      final stored = _syncPreferences.lastAttempt;
      final last = stored is int
          ? DateTime.fromMillisecondsSinceEpoch(stored)
          : null;
      final interval = Duration(minutes: intervalMinutes);
      // A clock moved backwards must not delay syncing indefinitely.
      final elapsed = last == null ? interval : _now.difference(last);
      final remaining = interval - (elapsed.isNegative ? interval : elapsed);
      if (remaining > Duration.zero) {
        _scheduleTimer = Timer(remaining, checkForAutomaticSync);
        return;
      }
    }
    // Do not download over local edits waiting for their next scheduled upload.
    unawaited(hasPendingChanges ? uploadData() : downloadData());
  }

  /// Save a draft only after its initial transfer succeeds. Automatic work is
  /// suspended while validating it, and existing transfers finish first.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required DataSyncMode syncMode,
    required int minutes,
    required bool initialUpload,
  }) async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_configuring) return const Res.error('Sync configuration is busy');
    _configuring = true;
    _scheduleTimer?.cancel();
    while (_activeTask != null || _pendingTask != null) {
      await (_pendingTask ?? _activeTask!);
    }
    final previous = _syncPreferences.capture();
    final previousGeneration = _changeGeneration;
    var committed = false;
    try {
      _syncPreferences.applyDraft(config, excludedFields);
      if (config.isNotEmpty && !hasConfiguration) {
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isNotEmpty && syncMode != DataSyncMode.manual) {
        final result = initialUpload
            ? await uploadData()
            : await downloadData();
        if (result.error) return result;
      }
      final selected = config.isEmpty ? DataSyncMode.manual : syncMode;
      _syncPreferences.setSchedule(selected, minutes);
      _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
      if (config.isEmpty) _syncPreferences.pending = false;
      appdata.writeImplicitData();
      await appdata.saveData(false);
      committed = true;
      return const Res(true);
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      return Res.error(error.toString());
    } finally {
      if (!committed) {
        _syncPreferences.restore(previous);
        if (_changeGeneration != previousGeneration && hasConfiguration) {
          _syncPreferences.pending = true;
        }
        appdata.writeImplicitData();
        await appdata.saveData(false);
      }
      _configuring = false;
      _lastRealtimeCheck = _now;
      if (mode == DataSyncMode.scheduled) checkForAutomaticSync();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> waitForUpload() => _waitForTask(_DataSyncTask.upload);

  Future<void> waitForDownload() async {
    return _waitForTask(_DataSyncTask.download);
  }

  Future<void> _waitForTask(_DataSyncTask task) async {
    while (true) {
      Future<Res<bool>>? taskFuture;
      if (_pendingTaskType == task) {
        taskFuture = _pendingTask;
      } else if (_activeTaskType == task) {
        taskFuture = _activeTask;
      }
      if (taskFuture == null) {
        return;
      }
      await taskFuture;
    }
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  @visibleForTesting
  static Future<Res<bool>> Function()? debugUploadOverride;

  @visibleForTesting
  static Future<Res<bool>> Function()? debugDownloadOverride;

  @visibleForTesting
  static void resetForTesting() {
    instance?.dispose();
    instance = null;
    debugUploadOverride = null;
    debugDownloadOverride = null;
    debugNow = null;
  }

  bool _isDownloading = false;
  bool _downloadApplied = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  Future<Res<bool>>? _activeTask;

  Future<Res<bool>>? _pendingTask;

  _DataSyncTask? _activeTaskType;

  _DataSyncTask? _pendingTaskType;

  String? _lastError;

  String? get lastError => _lastError;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scheduleTimer?.cancel();
    if (_started) {
      appdata.registerSyncDataRequestHandler(null);
      LocalFavoritesManager().removeListener(onDataChanged);
      ComicSourceManager().removeListener(onDataChanged);
    }
    super.dispose();
  }

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isConfigured: hasConfiguration,
    isEnabled: isEnabled,
    isUploading: _isUploading,
    isDownloading: _isDownloading,
    lastSyncTime: (appdata.settings['lastSyncTime'] as int?) ?? 0,
    lastError: _lastError,
  );

  bool get isEnabled => mode != DataSyncMode.manual && hasConfiguration;

  WebDavEndpoint? _validateConfig() {
    final connection = _syncPreferences.configuration.connection;
    return connection == null
        ? null
        : WebDavEndpoint(
            url: connection.url,
            user: connection.user,
            password: connection.password,
          );
  }

  Future<Res<bool>> uploadData() async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_activeTaskType == _DataSyncTask.download) {
      return const Res(true);
    }
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.upload, _uploadDataNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadDataNow);
  }

  Future<Res<bool>> downloadData() async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.download, _downloadDataNow);
    }
    return _startTask(_DataSyncTask.download, _downloadDataNow);
  }

  Future<Res<bool>> _schedulePendingTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    if (_pendingTask != null) {
      return Future.value(const Res(true));
    }
    var activeTask = _activeTask!;
    _pendingTaskType = task;
    var pendingTask = activeTask.then(
      (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        return _startTask(task, run);
      },
      onError: (_) {
        _pendingTask = null;
        _pendingTaskType = null;
        return _startTask(task, run);
      },
    );
    _pendingTask = pendingTask;
    return pendingTask;
  }

  Future<Res<bool>> _startTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) {
    if (_disposed) {
      return Future.value(const Res.error('Sync service is disposed'));
    }
    late Future<Res<bool>> activeTask;
    activeTask = _runTask(task, run).whenComplete(() {
      if (identical(_activeTask, activeTask)) {
        _activeTask = null;
        if (mode == DataSyncMode.scheduled && _pendingTask == null) {
          checkForAutomaticSync();
        }
      }
    });
    _activeTask = activeTask;
    return activeTask;
  }

  Future<Res<bool>> _runTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run,
  ) async {
    _activeTaskType = task;
    _isUploading = task == _DataSyncTask.upload;
    _isDownloading = task == _DataSyncTask.download;
    _downloadApplied = false;
    _lastError = null;
    final generation = _changeGeneration;
    if (hasConfiguration && !_configuring) {
      _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
      appdata.writeImplicitData();
    }
    notifyListeners();
    try {
      final result = await run();
      if (_disposed) return result;
      if (result.error) {
        _lastError = result.errorMessage;
      } else if (hasConfiguration &&
          generation == _changeGeneration &&
          (task == _DataSyncTask.upload || _downloadApplied)) {
        _syncPreferences.pending = false;
      }
      return result;
    } catch (e, s) {
      Log.error(_taskLogTag(task), e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      _activeTaskType = null;
      _isUploading = false;
      _isDownloading = false;
      if (hasConfiguration && !_configuring && !_disposed) {
        _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
        appdata.writeImplicitData();
      }
      if (!_disposed) notifyListeners();
    }
  }

  String _taskLogTag(_DataSyncTask task) {
    return task == _DataSyncTask.upload ? 'Upload Data' : 'Data Sync';
  }

  Future<Res<bool>> _uploadDataNow() async {
    var debugUpload = debugUploadOverride;
    if (debugUpload != null) {
      return debugUpload();
    }
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    var client = config.createClient(logRequests: true);

    try {
      appdata.settings['dataVersion']++;
      await appdata.saveData(false);
      var data = await exportAppData(
        _syncPreferences.configuration.excludedFields.isNotEmpty,
      );
      var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
      var filename = time;
      filename += '-';
      filename += appdata.settings['dataVersion'].toString();
      filename += '.venera';
      var files = await client.readDir('/');
      files = files.where((e) => e.name!.endsWith('.venera')).toList();
      var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
      if (old != null) {
        await client.remove(old.name!);
      }
      if (files.length >= 10) {
        files.sort((a, b) => a.name!.compareTo(b.name!));
        await client.remove(files.first.name!);
      }
      await client.write(filename, await data.readAsBytes());
      data.deleteIgnoreError();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Upload Data", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> _downloadDataNow() async {
    var debugDownload = debugDownloadOverride;
    if (debugDownload != null) {
      return debugDownload();
    }
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    var client = config.createClient(logRequests: true);

    try {
      var files = await client.readDir('/');
      files.sort((a, b) => b.name!.compareTo(a.name!));
      var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
      if (file == null) {
        throw 'No data file found';
      }
      var version = file.name!.split('-').elementAtOrNull(1)?.split('.').first;
      if (version != null && int.tryParse(version) != null) {
        var currentVersion = appdata.settings['dataVersion'];
        if (currentVersion != null && int.parse(version) <= currentVersion) {
          Log.info("Data Sync", 'No new data to download');
          return const Res(true);
        }
      }
      Log.info("Data Sync", "Downloading data from WebDAV server");
      var localFile = File(FilePath.join(App.cachePath, file.name!));
      await client.read2File(file.name!, localFile.path);
      await importAppData(localFile, true);
      _downloadApplied = true;
      await localFile.delete();
      HistoryManager().notifyChanges();
      LocalFavoritesManager().notifyChanges();
      ImageFavoriteManager().notifyChanges();
      appdata.settings['lastSyncTime'] = DateTime.now().millisecondsSinceEpoch;
      await appdata.saveData(false);
      Log.info("Data Sync", "Data downloaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Data Sync", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    }
  }
}
