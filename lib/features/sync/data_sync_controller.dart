import 'package:venera_next/network/request_scope.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/webdav.dart';
import 'data_sync_transfer.dart';

enum _DataSyncTask { upload, download }

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

class DataSyncController with ChangeNotifier {
  DataSyncController({
    required SyncPreferenceStore preferences,
    required DataSyncTransfer Function() transfer,
    required Future<void> Function() saveSettings,
    required void Function() persistImplicit,
    required void Function() Function(void Function()) observeChanges,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
  }) : _syncPreferences = preferences,
       _transferFactory = transfer,
       _saveSettings = saveSettings,
       _persistImplicit = persistImplicit,
       _observeChanges = observeChanges,
       _clock = now ?? DateTime.now,
       _createTimer = createTimer ?? Timer.new;

  final SyncPreferenceStore _syncPreferences;
  final DataSyncTransfer Function() _transferFactory;
  DataSyncTransfer? _transfer;
  RequestScope? _transferScope;
  DataSyncTransfer get _dataTransfer => _transfer ??= _transferFactory();
  final Future<void> Function() _saveSettings;
  final void Function() _persistImplicit;

  /// Subscribing must be atomic; the returned callback releases this subscription.
  final void Function() Function(void Function()) _observeChanges;
  final DateTime Function() _clock;
  final Timer Function(Duration, void Function()) _createTimer;

  bool _started = false;
  void Function()? _unsubscribe;

  /// Attach automatic synchronization once, after core services are ready.
  void start() {
    if (_disposed) {
      throw StateError('Cannot start a disposed DataSyncController');
    }
    if (_started) return;
    _started = true;
    try {
      _unsubscribe ??= _observeChanges(onDataChanged);
      checkForAutomaticSync(startup: true);
    } catch (_) {
      stop();
      final unsubscribe = _unsubscribe;
      _unsubscribe = null;
      unsubscribe?.call();
      rethrow;
    }
  }

  /// Stop automatic scheduling without canceling requested transfers.
  /// Keep observing local changes until dispose so edits made while the window
  /// is detached cannot be overwritten by a download after the next start.
  void stop() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _started = false;
  }

  void onDataChanged() {
    // Import notifications describe the downloaded snapshot, not local edits.
    if (_disposed || _isDownloading || !hasConfiguration) return;
    _changeGeneration++;
    if (!hasPendingChanges) {
      _syncPreferences.pending = true;
      _persistImplicit();
    }
    if (_started &&
        isEnabled &&
        currentMode == DataSyncMode.realtime &&
        !_configuring) {
      unawaited(uploadData());
    }
  }

  DataSyncMode get currentMode => _syncPreferences.configuration.mode;

  int get currentIntervalMinutes =>
      _syncPreferences.configuration.intervalMinutes;

  bool get hasConfiguration => _validateConfig()?.isValid == true;

  bool get hasPendingChanges => _syncPreferences.pending;

  Timer? _scheduleTimer;
  bool _disposed = false;
  bool _configuring = false;
  int _changeGeneration = 0;
  DateTime? _lastRealtimeCheck;

  DateTime get _now => _clock();

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
    if (currentMode == DataSyncMode.realtime) {
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
      final interval = Duration(minutes: currentIntervalMinutes);
      // A clock moved backwards must not delay syncing indefinitely.
      final elapsed = last == null ? interval : _now.difference(last);
      final remaining = interval - (elapsed.isNegative ? interval : elapsed);
      if (remaining > Duration.zero) {
        _scheduleTimer = _createTimer(remaining, checkForAutomaticSync);
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
    SyncPreferenceCheckpoint? previous;
    var previousGeneration = _changeGeneration;
    var committed = false;
    var result = const Res<bool>(true);
    try {
      while (_activeTask != null || _pendingTask != null) {
        await (_pendingTask ?? _activeTask!);
      }
      if (_disposed) {
        result = const Res.error('Sync service is disposed');
      } else {
        previous = _syncPreferences.capture();
        previousGeneration = _changeGeneration;
        _syncPreferences.applyDraft(config, excludedFields);
        if (config.isNotEmpty && !hasConfiguration) {
          result = const Res.error('Invalid WebDAV configuration');
        } else if (config.isNotEmpty && syncMode != DataSyncMode.manual) {
          result = initialUpload ? await uploadData() : await downloadData();
        }
        if (_disposed) result = const Res.error('Sync service is disposed');
        if (result.success) {
          final selected = config.isEmpty ? DataSyncMode.manual : syncMode;
          _syncPreferences.setSchedule(selected, minutes);
          _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
          if (config.isEmpty) _syncPreferences.pending = false;
          _persistImplicit();
          await _saveSettings();
          if (_disposed) {
            result = const Res.error('Sync service is disposed');
          } else {
            committed = true;
          }
        }
      }
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      result = Res.error(error.toString());
    } finally {
      try {
        if (!committed && previous != null) {
          _syncPreferences.restore(previous);
          if (_changeGeneration != previousGeneration && hasConfiguration) {
            _syncPreferences.pending = true;
          }
          _persistImplicit();
          await _saveSettings();
        }
      } catch (error, stack) {
        Log.error('Data Sync rollback', error, stack);
        result = Res.error(
          '${result.errorMessage ?? 'Sync configuration failed'}; '
          'Failed to restore sync configuration: $error',
        );
      } finally {
        _configuring = false;
        if (!_disposed) {
          _lastRealtimeCheck = _now;
          if (currentMode == DataSyncMode.scheduled) checkForAutomaticSync();
          notifyListeners();
        }
      }
    }
    return result;
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
    _transferScope?.cancel();
    stop();
    final unsubscribe = _unsubscribe;
    _unsubscribe = null;
    try {
      unsubscribe?.call();
    } finally {
      super.dispose();
    }
  }

  DataSyncStatusSnapshot get statusSnapshot => DataSyncStatusSnapshot(
    isConfigured: hasConfiguration,
    isEnabled: isEnabled,
    isUploading: _isUploading,
    isDownloading: _isDownloading,
    lastSyncTime: _syncPreferences.lastSyncTime,
    lastError: _lastError,
  );

  bool get isEnabled => currentMode != DataSyncMode.manual && hasConfiguration;

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
      return _schedulePendingTask(_DataSyncTask.upload, _uploadNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadNow);
  }

  Future<Res<bool>> downloadData() async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.download, _downloadNow);
    }
    return _startTask(_DataSyncTask.download, _downloadNow);
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
        if (currentMode == DataSyncMode.scheduled && _pendingTask == null) {
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
      _persistImplicit();
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
        _persistImplicit();
      }
      if (!_disposed) notifyListeners();
    }
  }

  String _taskLogTag(_DataSyncTask task) {
    return task == _DataSyncTask.upload ? 'Upload Data' : 'Data Sync';
  }

  Future<Res<bool>> _uploadNow() async {
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    final scope = RequestScope();
    _transferScope = scope;
    try {
      await _dataTransfer.upload(
        config,
        excludeFields: _syncPreferences.configuration.excludedFields.isNotEmpty,
        scope: scope,
      );
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } catch (e, s) {
      Log.error("Upload Data", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      if (identical(_transferScope, scope)) _transferScope = null;
      scope.dispose();
    }
  }

  Future<Res<bool>> _downloadNow() async {
    var config = _validateConfig();
    if (config == null) {
      _lastError = 'Invalid WebDAV configuration';
      return const Res.error('Invalid WebDAV configuration');
    }
    if (!config.isValid) {
      return const Res(true);
    }
    final scope = RequestScope();
    _transferScope = scope;
    try {
      _downloadApplied = await _dataTransfer.download(config, scope: scope);
      Log.info(
        "Data Sync",
        _downloadApplied
            ? "Data downloaded successfully"
            : "No new data to download",
      );
      return const Res(true);
    } catch (e, s) {
      Log.error("Data Sync", e, s);
      _lastError = e.toString();
      return Res.error(e.toString());
    } finally {
      if (identical(_transferScope, scope)) _transferScope = null;
      scope.dispose();
    }
  }
}
