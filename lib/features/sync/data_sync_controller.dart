import 'package:venera_next/network/request_scope.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:uuid/uuid.dart';
import 'data_sync_commit.dart';
import 'data_sync_operation.dart';
import 'data_sync_transfer.dart';
import 'data_sync_recovery.dart';
import 'data_sync_content.dart';
import 'data_sync_ownership.dart';

enum _DataSyncTask { upload, download }

/// Only unfinished commit work survives a failed task. The original transfer
/// must never be re-entered merely because its receipt could not be saved.
class _SyncCompletion {
  _SyncCompletion({
    required this.operation,
    required this.result,
    required this.settingsPending,
    this.resume,
  });

  DataSyncOperation operation;
  final Res<bool> result;
  bool settingsPending;
  bool configurationPending = false;
  Future<void> Function()? restoreConfiguration;
  Future<DataSyncCommitState> Function(RequestScope)? resume;
  bool preservePending = false;
  bool preserveLastAttempt = false;
  bool markerCleared = false;
  bool receiptResolved = false;
  String? receiptId;
  bool recoveredUpload = false;
  DataSyncCommitState? recoveredConfigurationState;
}

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
    required FutureOr<void> Function() persistImplicit,
    required void Function() Function(void Function()) observeChanges,
    DataSyncImportRecovery? importRecovery,
    DataSyncUploadRecovery? uploadRecovery,
    DataSyncContent? content,
    DataSyncOwnership? ownership,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
  }) : _syncPreferences = preferences,
       _transferFactory = transfer,
       _saveSettings = saveSettings,
       _persistImplicit = persistImplicit,
       _observeChanges = observeChanges,
       _importRecovery = importRecovery,
       _uploadRecovery = uploadRecovery,
       _content = content,
       _ownership = ownership,
       _clock = now ?? DateTime.now,
       _createTimer = createTimer ?? Timer.new;

  final SyncPreferenceStore _syncPreferences;
  final DataSyncTransfer Function() _transferFactory;
  DataSyncTransfer? _transfer;
  RequestScope? _transferScope;
  DataSyncTransfer get _dataTransfer => _transfer ??= _transferFactory();
  final Future<void> Function() _saveSettings;
  final FutureOr<void> Function() _persistImplicit;
  final DataSyncImportRecovery? _importRecovery;
  final DataSyncUploadRecovery? _uploadRecovery;
  final DataSyncContent? _content;
  final DataSyncOwnership? _ownership;
  bool _ownershipReady = false;
  bool _ownershipReleased = false;
  bool _disposalDrained = false;
  Future<void>? _closing;
  Object? _disposalFailure;
  StackTrace? _disposalStack;

  void _acquireOwnership() {
    if (_ownershipReleased || _disposalDrained) {
      throw StateError('Sync ownership is closing');
    }
    _ownership?.acquire();
    _ownershipReady = true;
  }

  bool _tryOwnership() {
    try {
      _acquireOwnership();
      return true;
    } catch (error, stack) {
      Log.error('Data Sync ownership', error, stack);
      _lastError = error.toString();
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  bool _checkingContent = false;
  bool get _hasRecovery =>
      _importRecovery != null ||
      _uploadRecovery != null ||
      _content != null ||
      _ownership != null;
  bool _recoveryInitialized = false;
  bool _automaticRecoveryWait = false;
  Future<bool>? _recoveryPreparation;
  DataSyncFailure? _recoveryIoFailure;
  final _pendingRecoveryWork = <Future<void>>{};

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
    if (!_tryOwnership()) return;
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
    if (_disposed || _publishingImported) return;
    _changeGeneration++;
    if (!hasConfiguration) return;
    if (!_tryOwnership()) return;
    if (!hasPendingChanges) {
      _syncPreferences.pending = true;
      unawaited(
        Future<void>.sync(_persistState).catchError((
          Object error,
          StackTrace stack,
        ) {
          Log.error('Data Sync persistence', error, stack);
          if (!_disposed) {
            _lastError = error.toString();
            notifyListeners();
          }
        }),
      );
    }
    if (_started &&
        isEnabled &&
        currentMode == DataSyncMode.realtime &&
        !_exitHeld &&
        !_configuring) {
      if (_content == null) {
        unawaited(uploadData());
      } else {
        checkForAutomaticSync(startup: true);
      }
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
  bool _publishingImported = false;
  int _changeGeneration = 0;
  DataSyncCommitState _lastCommitState = DataSyncCommitState.notApplied;
  Future<DataSyncCommitState> Function(RequestScope)? _transferResume;
  DataSyncOperation? _ownedOperation;
  _SyncCompletion? _completion;
  DataSyncFailure? _recoveryFailure;
  DateTime? _lastRealtimeCheck;

  DateTime get _now => _clock();

  /// Called at startup and resume, independently of the home page being mounted.
  /// Timers only run in this process; overdue checks are caught up on next launch.
  void checkForAutomaticSync({bool startup = false}) {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    if (_hasRecovery && !_recoveryInitialized) {
      if (_started && !_disposed && !_exitHeld && !_automaticRecoveryWait) {
        _automaticRecoveryWait = true;
        unawaited(
          _prepareRecovery().then((failure) {
            _automaticRecoveryWait = false;
            if (failure == null && !_disposed && !_exitHeld) {
              checkForAutomaticSync(startup: startup);
            }
          }),
        );
      }
      return;
    }
    if (!_started ||
        _disposed ||
        _configuring ||
        _exitHeld ||
        _recoveryGuard() != null ||
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
    final completion = _completion;
    if (completion != null) {
      // Resolve accepted work before consulting a baseline it may still own.
      // A first interrupted upload has no baseline until recovery confirms it.
      final upload = completion.operation.direction == DataSyncDirection.upload;
      unawaited(
        _startTask(
          upload ? _DataSyncTask.upload : _DataSyncTask.download,
          upload ? _uploadNow : () => _downloadNow(),
        ),
      );
    } else if (_content == null) {
      unawaited(hasPendingChanges ? uploadData() : downloadData());
    } else if (!_checkingContent) {
      unawaited(_checkAutomaticContent());
    }
  }

  Future<void> _checkAutomaticContent() async {
    _checkingContent = true;
    final config = _syncPreferences.configuration;
    final connection = config.connection!;
    final values = [connection.url, connection.user, connection.password];
    try {
      final state = await _trackRecoveryIo(
        'compare synchronized content',
        () => _content!.inspect(values, config.excludedFields),
      );
      if (_disposed ||
          !_started ||
          !isEnabled ||
          _exitHeld ||
          _configuring ||
          _activeTask != null ||
          _pendingTask != null) {
        return;
      }
      final current = _syncPreferences.configuration;
      final endpoint = current.connection;
      if (endpoint == null ||
          !listEquals(values, [
            endpoint.url,
            endpoint.user,
            endpoint.password,
          ]) ||
          current.excludedFields != config.excludedFields ||
          current.mode != config.mode) {
        return;
      }
      if (state == DataSyncContentState.unknown) {
        throw const DataSyncBaselineUnavailable();
      }
      _syncPreferences.pending = state == DataSyncContentState.changed;
      // The synchronous _startTask call takes over admission immediately. Its
      // completion may schedule another check for edits made during transfer.
      _checkingContent = false;
      unawaited(
        _startTask(
          hasPendingChanges ? _DataSyncTask.upload : _DataSyncTask.download,
          hasPendingChanges ? _uploadNow : () => _downloadNow(),
          automatic: true,
        ),
      );
    } catch (error, stack) {
      Log.error('Data Sync content', error, stack);
      if (!_disposed) {
        _lastError = error.toString();
        notifyListeners();
      }
    } finally {
      _checkingContent = false;
    }
  }

  /// Restore the old endpoint only when the initial transfer did not apply.
  /// Once applied, failed persistence is resumed against the same draft.
  Future<Res<bool>> configure({
    required List<String> config,
    required String excludedFields,
    required DataSyncMode syncMode,
    required int minutes,
    required bool initialUpload,
  }) async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_configuring) return const Res.error('Sync configuration is busy');
    if (_exitHeld) return const Res.error('Sync service is preparing to exit');
    if (_hasRecovery && !_recoveryInitialized) {
      if (await _prepareRecovery() case final failure?) return failure;
      if (_disposed) return const Res.error('Sync service is disposed');
      if (_configuring) return const Res.error('Sync configuration is busy');
      if (_exitHeld) {
        return const Res.error('Sync service is preparing to exit');
      }
    }
    if (_recoveryGuard() case final failure?) return Res.failure(failure);
    _configuring = true;
    final configurationDone = _configurationDone = Completer<void>();
    _scheduleTimer?.cancel();
    SyncPreferenceCheckpoint? previous;
    var previousGeneration = _changeGeneration;
    var retainDraft = false;
    var result = const Res<bool>(true);
    final diagnostics = <DataSyncDiagnostic>[];
    try {
      while (_activeTask != null || _pendingTask != null) {
        await (_pendingTask ?? _activeTask!);
      }
      if (_disposed) {
        result = const Res.error('Sync service is disposed');
      } else {
        final pending = _completion;
        if (pending != null) {
          final operation = pending.operation;
          final sameDraft =
              listEquals(operation.connection, config) &&
              operation.excludedFields == excludedFields &&
              operation.mode == syncMode.name &&
              operation.intervalMinutes ==
                  SyncConfiguration.normalizeInterval(minutes);
          if (!sameDraft) {
            result = const Res.error(
              'Finish the pending sync before changing configuration',
            );
          } else {
            result = await _startTask(
              operation.direction == DataSyncDirection.upload
                  ? _DataSyncTask.upload
                  : _DataSyncTask.download,
              operation.direction == DataSyncDirection.upload
                  ? _uploadNow
                  : () => _downloadNow(),
            );
          }
        } else {
          previous = _syncPreferences.capture();
          previousGeneration = _changeGeneration;
          _syncPreferences.applyDraft(config, excludedFields);
          final selected = config.isEmpty ? DataSyncMode.manual : syncMode;
          _syncPreferences.setSchedule(selected, minutes);
          _lastCommitState = DataSyncCommitState.notApplied;
          var transferred = false;
          if (config.isNotEmpty && !hasConfiguration) {
            result = const Res.error('Invalid WebDAV configuration');
          } else if (config.isNotEmpty && syncMode != DataSyncMode.manual) {
            // This configuration was admitted before any exit barrier. Its
            // required transfer must finish even after public admissions close.
            result = initialUpload
                ? await _startTask(
                    _DataSyncTask.upload,
                    _uploadNow,
                    saveConfiguration: true,
                    previousConfiguration: previous,
                  )
                : await _startTask(
                    _DataSyncTask.download,
                    () => _downloadNow(),
                    saveConfiguration: true,
                    previousConfiguration: previous,
                  );
            transferred = true;
            retainDraft = _lastCommitState != DataSyncCommitState.notApplied;
          }
          if (result.success) {
            _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
            if (config.isEmpty) _syncPreferences.pending = false;
            if (!transferred) await _persistConfiguration();
            retainDraft = true;
          }
        }
      }
    } catch (error, stack) {
      Log.error('Data Sync', error, stack);
      result = Res.fromException(error, stack);
    } finally {
      try {
        if (!retainDraft && previous != null) {
          final checkpoint = previous;
          Future<void> restore() async {
            _syncPreferences.restore(checkpoint);
            if (_changeGeneration != previousGeneration && hasConfiguration) {
              _syncPreferences.pending = true;
            }
            await _persistConfiguration();
          }

          // A not-applied transfer may still own temporary-file cleanup. Its
          // continuation must not persist the rejected endpoint again.
          final completion = _completion;
          if (completion != null) {
            completion.settingsPending = false;
            completion.configurationPending = true;
            completion.restoreConfiguration = restore;
          }
          await restore();
          if (completion != null) {
            completion.restoreConfiguration = null;
            completion.configurationPending = false;
            if (completion.resume == null) {
              final finalization = await _finishCompletion(
                completion,
                retry: true,
                retainOriginalFailure: false,
              );
              if (finalization.error) {
                final failures = <DataSyncDiagnostic>[];
                _appendFailure(failures, 'configuration', result);
                _appendFailure(
                  failures,
                  'finish configuration rollback',
                  finalization,
                );
                result = Res.failure(
                  DataSyncFailure(
                    commitState: _lastCommitState,
                    failures: failures,
                  ),
                );
              }
            }
          }
        }
      } catch (error, stack) {
        Log.error('Data Sync rollback', error, stack);
        _appendFailure(diagnostics, 'configuration', result);
        _appendDiagnostic(diagnostics, 'restore configuration', error, stack);
        result = Res.failure(
          DataSyncFailure(commitState: _lastCommitState, failures: diagnostics),
        );
      } finally {
        _configuring = false;
        _configurationDone = null;
        configurationDone.complete();
        if (!_disposed) {
          _lastError = result.errorMessage;
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
    await _drainRecoveryPreparation();
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
      if (_ownership != null) {
        unawaited(
          _closeOwned().catchError((Object error, StackTrace stack) {
            Log.error('Data Sync shutdown', error, stack);
          }),
        );
      }
    }
  }

  /// Detach immediately, then await accepted work, final persistence and native
  /// ownership release. Failed release can be retried without replaying writes.
  Future<void> closeAndWait() {
    dispose();
    return _ownership == null ? _flushPersistence() : _closeOwned();
  }

  Future<void> _closeOwned() {
    final closing = _closing;
    if (closing != null) return closing;
    return _closing = _closeOwnedNow().catchError((
      Object error,
      StackTrace stack,
    ) {
      if (!_ownershipReleased) _closing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _closeOwnedNow() async {
    if (!_disposalDrained) {
      try {
        await _flushPersistence();
      } catch (error, stack) {
        if (!identical(error, _recoveryIoFailure)) rethrow;
        // An already reported recovery error is not a running task. Retain it
        // for the caller while still flushing and closing concrete resources.
        _disposalFailure = error;
        _disposalStack = stack;
        await Future<void>.sync(_persistState);
        while (_pendingPersistence.isNotEmpty) {
          await Future.wait(List.of(_pendingPersistence));
        }
      }
      _disposalDrained = true;
    }
    await _content?.close();
    _ownership!.release();
    _ownershipReleased = true;
    if (_disposalFailure case final failure?) {
      Error.throwWithStackTrace(failure, _disposalStack!);
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
    if (_exitHeld) return const Res.error('Sync service is preparing to exit');
    if (_configuring) return const Res.error('Sync configuration is busy');
    if (_hasRecovery && !_recoveryInitialized) {
      if (await _prepareRecovery() case final failure?) return failure;
    }
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_exitHeld) return const Res.error('Sync service is preparing to exit');
    if (_configuring) return const Res.error('Sync configuration is busy');
    if (_recoveryGuard() case final failure?) return Res.failure(failure);
    if (_completion != null && _activeTask != null) return _activeTask!;
    if (_activeTaskType == _DataSyncTask.download) {
      return const Res(true);
    }
    if (_activeTask != null) {
      return _schedulePendingTask(_DataSyncTask.upload, _uploadNow);
    }
    return _startTask(_DataSyncTask.upload, _uploadNow);
  }

  Future<Res<bool>> downloadData({bool force = false}) async {
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_exitHeld) return const Res.error('Sync service is preparing to exit');
    if (_configuring) return const Res.error('Sync configuration is busy');
    if (_hasRecovery && !_recoveryInitialized) {
      if (await _prepareRecovery() case final failure?) return failure;
    }
    if (_disposed) return const Res.error('Sync service is disposed');
    if (_exitHeld) return const Res.error('Sync service is preparing to exit');
    if (_configuring) return const Res.error('Sync configuration is busy');
    if (_recoveryGuard() case final failure?) return Res.failure(failure);
    if (_completion != null && _activeTask != null) return _activeTask!;
    if (_activeTask != null) {
      return _schedulePendingTask(
        _DataSyncTask.download,
        () => _downloadNow(force: force),
      );
    }
    return _startTask(_DataSyncTask.download, () => _downloadNow(force: force));
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

  Completer<void>? _configurationDone;
  Future<VoidCallback>? _exitPreparation;
  bool _exitHeld = false;
  int _exitGeneration = 0;

  /// Freeze admissions until the host exits or releases this preparation.
  /// Accepted configuration/transfer work is allowed to finish before saving.
  Future<VoidCallback> prepareForExit() {
    if (_disposed) return Future.error(StateError('Sync service is disposed'));
    final existing = _exitPreparation;
    if (existing != null) return existing;
    _exitHeld = true;
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    final generation = ++_exitGeneration;
    void release() {
      if (!_exitHeld || generation != _exitGeneration) return;
      _exitHeld = false;
      _exitPreparation = null;
      if (!_disposed) checkForAutomaticSync();
    }

    return _exitPreparation = _prepareForExit(release);
  }

  Future<VoidCallback> _prepareForExit(VoidCallback release) async {
    try {
      await _drainRecoveryPreparation();
      final configuring = _configurationDone;
      if (configuring != null) await configuring.future;
      while (_activeTask != null || _pendingTask != null) {
        await (_pendingTask ?? _activeTask!);
      }
      await flushPersistence();
      return release;
    } catch (_) {
      release();
      rethrow;
    }
  }

  final _pendingPersistence = <Future<void>>{};

  FutureOr<void> _persistState() {
    if (_ownership != null) {
      if (_disposalDrained || (_disposed && !_ownershipReady)) return null;
      _acquireOwnership();
    }
    final result = _persistImplicit();
    if (result is! Future<void>) return null;
    late Future<void> tracked;
    tracked = result.whenComplete(() => _pendingPersistence.remove(tracked));
    _pendingPersistence.add(tracked);
    return tracked;
  }

  /// Persist the latest state (also retrying an earlier failed background save)
  /// and drain writes accepted while flushing. This does not stop scheduling.
  Future<void> flushPersistence() =>
      _disposed && _ownership != null ? _closeOwned() : _flushPersistence();

  Future<void> _flushPersistence() async {
    if (_disposed) {
      // Accepted transfers can still own journal reads and committed follow-up
      // writes. Their implementation uses _persistState, never this flush.
      final configuring = _configurationDone;
      if (configuring != null) await configuring.future;
      while (_activeTask != null || _pendingTask != null) {
        await (_pendingTask ?? _activeTask!);
      }
    }
    await _drainRecoveryPreparation();
    await Future<void>.sync(_persistState);
    while (_pendingPersistence.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pendingPersistence));
    }
  }

  /// Both files must settle before commit or rollback. A failure writing one
  /// must not prevent attempting to restore the other.
  Future<void> _persistConfiguration({void Function()? settingsSaved}) async {
    final failures = <DataSyncDiagnostic>[];
    Future<void> save(String stage, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        _appendDiagnostic(failures, stage, error, stack);
      }
    }

    await Future.wait([
      save('save implicit sync state', _persistState),
      save('save sync settings', () async {
        await _saveSettings();
        settingsSaved?.call();
      }),
    ]);
    if (failures.isNotEmpty) {
      throw DataSyncFailure(commitState: _lastCommitState, failures: failures);
    }
  }

  Future<Res<bool>?> _prepareRecovery() async {
    Future<bool>? preparation;
    try {
      _acquireOwnership();
      if (!_hasRecovery || _recoveryInitialized) return null;
      preparation = _recoveryPreparation ??= _loadImportRecovery();
      _recoveryInitialized = await preparation;
      _recoveryIoFailure = null;
      return null;
    } catch (error, stack) {
      final failure = _retainRecoveryIoFailure(
        'read import recovery',
        error,
        stack,
        commitState: DataSyncCommitState.recoveryRequired,
      );
      _lastError = failure.message;
      if (!_disposed) notifyListeners();
      return Res.failure(failure);
    } finally {
      if (identical(_recoveryPreparation, preparation)) {
        _recoveryPreparation = null;
      }
    }
  }

  DataSyncFailure _retainRecoveryIoFailure(
    String stage,
    Object error,
    StackTrace stack, {
    DataSyncCommitState? commitState,
  }) {
    final failures = <DataSyncDiagnostic>[];
    _appendDiagnostic(failures, stage, error, stack);
    return _recoveryIoFailure = DataSyncFailure(
      commitState: commitState ?? _lastCommitState,
      failures: failures,
    );
  }

  Future<void> _drainRecoveryPreparation() async {
    final preparation = _recoveryPreparation;
    if (preparation != null) {
      try {
        await preparation;
      } catch (error, stack) {
        _retainRecoveryIoFailure(
          'read import recovery',
          error,
          stack,
          commitState: DataSyncCommitState.recoveryRequired,
        );
      }
    }
    while (_pendingRecoveryWork.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pendingRecoveryWork));
    }
    if (_recoveryIoFailure case final failure?) throw failure;
  }

  Future<T> _trackRecoveryIo<T>(String stage, FutureOr<T> Function() action) {
    final result = Future<T>.sync(action);
    late Future<void> tracked;
    tracked = result
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _retainRecoveryIoFailure(stage, error, stack);
          },
        )
        .whenComplete(() => _pendingRecoveryWork.remove(tracked));
    _pendingRecoveryWork.add(tracked);
    return result;
  }

  Future<void> _acknowledgeReceipt(String id) => _trackRecoveryIo(
    'acknowledge import receipt',
    () => _importRecovery!.acknowledge(id),
  );

  Future<List<DataSyncImportReceipt>> _readImportReceipts() =>
      _trackRecoveryIo('read import receipt', _importRecovery!.readReceipts);

  Future<bool> _loadImportRecovery() async {
    final raw = _syncPreferences.pendingOperation;
    DataSyncOperation? operation;
    if (raw != null) {
      try {
        operation = DataSyncOperation.fromJson(raw);
      } on FormatException {
        return true; // The synchronous guard retains the corrupt marker.
      }
    }
    final unstartedDownload = _content == null
        ? false
        : await _trackRecoveryIo(
            'recover synchronized content',
            () => _content.recover(operation),
          );
    if (_disposed || _exitHeld) return false;
    if (operation != null) {
      if (operation.direction == DataSyncDirection.upload) {
        if (operation.version >= 3 && _uploadRecovery != null) {
          _installRecoveredUpload(operation);
        }
        return true;
      }
      if (operation.version < 2) {
        return true;
      }
    }
    if (operation == null && _uploadRecovery != null) {
      final uploads = _uploadRecovery;
      final ids = await _trackRecoveryIo(
        'read upload receipts',
        uploads.listTerminalUploadOperations,
      );
      for (final id in ids) {
        if (_disposed || _exitHeld) return false;
        await _trackRecoveryIo(
          'acknowledge upload receipt',
          () => uploads.acknowledgeUpload(id),
        );
      }
      if (_disposed || _exitHeld) return false;
    }
    final recovery = _importRecovery;
    if (recovery == null) return true;
    final receipts = await _readImportReceipts();
    if (_disposed || _exitHeld) return false;
    if (operation == null) {
      // The controller marker was durably removed before an interrupted ack.
      // Cleaning terminal owned receipts says nothing about local dirty state.
      for (final receipt in receipts) {
        if (_disposed || _exitHeld) return false;
        if (receipt.syncOperationId != null &&
            receipt.commitState != DataSyncCommitState.recoveryRequired) {
          await _acknowledgeReceipt(receipt.id);
        }
      }
      return !_disposed && !_exitHeld;
    }
    final matches = receipts
        .where((receipt) => receipt.syncOperationId == operation!.id)
        .toList();
    if (matches.length != 1 && !(matches.isEmpty && unstartedDownload)) {
      return true;
    }
    final receipt = matches.isEmpty ? null : matches.single;
    final state = receipt?.commitState ?? DataSyncCommitState.notApplied;
    if (state == DataSyncCommitState.recoveryRequired ||
        (state == DataSyncCommitState.applied &&
            !receipt!.hasValidCommitTime)) {
      return true;
    }
    final restored = operation.copyWith(commitState: state);
    final completion =
        _SyncCompletion(
            operation: restored,
            result: const Res(true),
            settingsPending: state == DataSyncCommitState.applied,
          )
          ..preservePending = true
          ..receiptResolved = true
          ..receiptId = receipt?.id;
    if (state == DataSyncCommitState.applied) {
      _syncPreferences.applyDraft(
        operation.connection,
        operation.excludedFields,
      );
      _syncPreferences.setSchedule(
        DataSyncMode.values.byName(operation.mode),
        operation.intervalMinutes,
      );
      var notified = false;
      var recorded = false;
      completion.resume = (_) async {
        if (!notified) {
          _publishImported(recovery.notifyImported);
          notified = true;
        }
        if (!recorded) {
          await recovery.recordSyncTime(receipt!.committedAt!);
          recorded = true;
        }
        return DataSyncCommitState.applied;
      };
    } else if (operation.configurationChange) {
      completion.configurationPending = true;
      completion.preserveLastAttempt = true;
      completion.restoreConfiguration = () async {
        _syncPreferences.restore(operation!.previousConfiguration!);
        // A restarted generation cannot establish that there were no edits.
        _syncPreferences.pending = true;
        await _persistConfiguration();
      };
    }
    _syncPreferences.pending = true;
    _lastCommitState = state;
    _ownedOperation = restored;
    _completion = completion;
    _recoveryFailure = null;
    return true;
  }

  WebDavEndpoint _operationEndpoint(DataSyncOperation operation) {
    if (operation.connection.length != 3) {
      throw const FormatException('Missing original sync endpoint');
    }
    return WebDavEndpoint(
      url: operation.connection[0],
      user: operation.connection[1],
      password: operation.connection[2],
    );
  }

  void _installRecoveredUpload(DataSyncOperation operation) {
    final endpoint = _operationEndpoint(operation);
    final uncertain = operation.copyWith(
      commitState: DataSyncCommitState.recoveryRequired,
      followUpComplete: false,
    );
    final completion =
        _SyncCompletion(
            operation: uncertain,
            result: const Res(true),
            settingsPending: false,
            resume: (scope) => _trackRecoveryIo(
              'recover upload',
              () => _uploadRecovery!.recoverUpload(
                endpoint,
                syncOperationId: operation.id,
                scope: scope,
              ),
            ),
          )
          ..preservePending = true
          ..recoveredUpload = true;
    _ownedOperation = uncertain;
    _completion = completion;
    _lastCommitState = DataSyncCommitState.recoveryRequired;
    _syncPreferences.pending = true;
    _recoveryFailure = null;
  }

  void _restoreRecoveredUploadConfiguration(_SyncCompletion completion) {
    if (!completion.recoveredUpload ||
        completion.recoveredConfigurationState == _lastCommitState) {
      return;
    }
    final operation = completion.operation;
    if (_lastCommitState == DataSyncCommitState.applied) {
      _syncPreferences.applyDraft(
        operation.connection,
        operation.excludedFields,
      );
      _syncPreferences.setSchedule(
        DataSyncMode.values.byName(operation.mode),
        operation.intervalMinutes,
      );
      completion.settingsPending = true;
      completion.configurationPending = false;
      completion.restoreConfiguration = null;
      completion.preserveLastAttempt = false;
      completion.recoveredConfigurationState = _lastCommitState;
    } else if (_lastCommitState == DataSyncCommitState.notApplied) {
      completion.recoveredConfigurationState = _lastCommitState;
      if (operation.configurationChange) {
        completion.configurationPending = true;
        completion.preserveLastAttempt = true;
        completion.restoreConfiguration = () async {
          _syncPreferences.restore(operation.previousConfiguration!);
          _syncPreferences.pending = true;
          await _persistConfiguration();
        };
      }
    }
  }

  void _publishImported(void Function() publish) {
    final previous = _publishingImported;
    _publishingImported = true;
    try {
      publish();
    } finally {
      _publishingImported = previous;
    }
  }

  DataSyncFailure? _recoveryGuard() {
    if (_recoveryFailure case final failure?) {
      if (_completion?.resume == null) return failure;
      _recoveryFailure = null;
    }
    final raw = _syncPreferences.pendingOperation;
    if (raw == null) return null;
    try {
      final operation = DataSyncOperation.fromJson(raw);
      if (operation.id == _ownedOperation?.id) return null;
      _recoveryFailure = DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        recoveryPath: operation.recoveryPath,
        failures: [
          (
            stage: 'recover sync operation',
            error: StateError(
              'Unfinished sync operation ${operation.id} requires recovery',
            ),
            stack: StackTrace.current,
          ),
        ],
      );
    } catch (error, stack) {
      _recoveryFailure = DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        failures: [(stage: 'read sync operation', error: error, stack: stack)],
      );
    }
    _lastError = _recoveryFailure!.message;
    return _recoveryFailure;
  }

  Future<Res<bool>> _startTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run, {
    bool saveConfiguration = false,
    SyncPreferenceCheckpoint? previousConfiguration,
    bool automatic = false,
  }) {
    if (_disposed) {
      return Future.value(const Res.error('Sync service is disposed'));
    }
    if (_recoveryGuard() case final failure?) {
      return Future.value(Res.failure(failure));
    }
    late Future<Res<bool>> activeTask;
    activeTask =
        _runTask(
          task,
          run,
          saveConfiguration: saveConfiguration,
          previousConfiguration: previousConfiguration,
          automatic: automatic,
        ).whenComplete(() {
          if (identical(_activeTask, activeTask)) {
            _activeTask = null;
            if (currentMode == DataSyncMode.scheduled && _pendingTask == null) {
              checkForAutomaticSync();
            } else if (_started &&
                !_disposed &&
                !_configuring &&
                !_exitHeld &&
                currentMode == DataSyncMode.realtime &&
                _pendingTask == null &&
                _completion == null &&
                _lastCommitState == DataSyncCommitState.applied &&
                hasPendingChanges) {
              // A queued local edit may have joined the old receipt's retry.
              // Its new generation still needs an upload of its own.
              if (_content == null) {
                unawaited(uploadData());
              } else {
                checkForAutomaticSync(startup: true);
              }
            }
          }
        });
    _activeTask = activeTask;
    return activeTask;
  }

  Future<Res<bool>> _runTask(
    _DataSyncTask task,
    Future<Res<bool>> Function() run, {
    required bool saveConfiguration,
    SyncPreferenceCheckpoint? previousConfiguration,
    required bool automatic,
  }) async {
    final pending = _completion;
    final effectiveTask = pending == null
        ? task
        : pending.operation.direction == DataSyncDirection.upload
        ? _DataSyncTask.upload
        : _DataSyncTask.download;
    _activeTaskType = effectiveTask;
    _isUploading = effectiveTask == _DataSyncTask.upload;
    _isDownloading = effectiveTask == _DataSyncTask.download;
    _lastError = null;
    _lastCommitState =
        pending?.operation.commitState ?? DataSyncCommitState.notApplied;
    _transferResume = null;
    try {
      notifyListeners();
      if (_disposed) return const Res.error('Sync service is disposed');
      if (pending != null) {
        return await _finishCompletion(pending, retry: true);
      }
      if (!hasConfiguration) return await run();
      final config = _syncPreferences.configuration;
      final connection = config.connection!;
      final operation = DataSyncOperation(
        version: _content != null
            ? 4
            : task == _DataSyncTask.upload && _uploadRecovery != null
            ? 3
            : 2,
        id: const Uuid().v4(),
        direction: task == _DataSyncTask.upload
            ? DataSyncDirection.upload
            : DataSyncDirection.download,
        connection: [connection.url, connection.user, connection.password],
        excludedFields: config.excludedFields,
        mode: config.mode.name,
        intervalMinutes: config.intervalMinutes,
        generation: _changeGeneration,
        pendingBefore: hasPendingChanges,
        commitState: DataSyncCommitState.notApplied,
        followUpComplete: false,
        configurationChange: saveConfiguration,
        previousConfiguration: previousConfiguration,
      );
      if (_content != null) {
        await _trackRecoveryIo(
          'prepare synchronized content',
          () => _content.prepare(operation, automatic: automatic),
        );
      }
      _ownedOperation = operation;
      _syncPreferences.pendingOperation = operation.toJson();
      _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
      try {
        // No remote write or local import can begin before the intent settles.
        final saving = _persistState();
        if (saving is Future<void>) await saving;
      } catch (_) {
        // This process knows no transfer began. A possibly written marker on
        // disk remains conservative after restart; an in-process retry is safe.
        _ownedOperation = null;
        _syncPreferences.pendingOperation = null;
        rethrow;
      }
      final result = _disposed
          ? const Res<bool>.error('Sync service is disposed')
          : await run();
      final completion = _completion = _SyncCompletion(
        operation: operation.copyWith(
          commitState: _lastCommitState,
          followUpComplete: _transferResume == null,
          recoveryPath: result.failure is DataSyncFailure
              ? (result.failure as DataSyncFailure).recoveryPath
              : null,
        ),
        result: result,
        settingsPending:
            saveConfiguration &&
            (result.success ||
                _lastCommitState != DataSyncCommitState.notApplied),
        resume: _transferResume,
      );
      completion.configurationPending =
          saveConfiguration &&
          result.error &&
          _lastCommitState == DataSyncCommitState.notApplied;
      completion.recoveredUpload =
          operation.version >= 3 &&
          operation.direction == DataSyncDirection.upload &&
          _transferResume != null;
      return await _finishCompletion(completion, retry: false);
    } catch (error, stack) {
      Log.error(_taskLogTag(effectiveTask), error, stack);
      final result = Res<bool>.fromException(error, stack);
      _lastError = result.errorMessage;
      return result;
    } finally {
      _activeTaskType = null;
      _isUploading = false;
      _isDownloading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<Res<bool>> _finishCompletion(
    _SyncCompletion completion, {
    required bool retry,
    bool retainOriginalFailure = true,
  }) async {
    final failures = <DataSyncDiagnostic>[];
    if (completion.markerCleared) {
      return _acknowledgeCompletion(completion, failures);
    }
    Res<bool>? original;
    if (!retry) {
      original = completion.result;
      _appendFailure(failures, 'transfer', original);
    } else if (completion.resume case final resume?) {
      final scope = RequestScope();
      _transferScope = scope;
      try {
        _lastCommitState = await resume(scope);
        completion.resume = null;
      } catch (error, stack) {
        if (error is DataSyncFailure) {
          _lastCommitState = error.commitState;
          if (error is DataSyncTransferFailure && error.resume != null) {
            completion.resume = error.resume;
          }
        }
        _appendDiagnostic(failures, 'finish transfer', error, stack);
      } finally {
        if (identical(_transferScope, scope)) _transferScope = null;
        scope.dispose();
      }
    }
    if (retry &&
        retainOriginalFailure &&
        _lastCommitState == DataSyncCommitState.notApplied) {
      // Finishing cleanup does not turn a failed transfer into a successful one.
      original = completion.result;
      _appendFailure(failures, 'transfer', original);
    }
    _restoreRecoveredUploadConfiguration(completion);
    if (completion.restoreConfiguration case final restore? when retry) {
      try {
        await restore();
        completion.restoreConfiguration = null;
        completion.configurationPending = false;
      } catch (error, stack) {
        _appendDiagnostic(failures, 'restore configuration', error, stack);
      }
    }
    if (_lastCommitState == DataSyncCommitState.applied) {
      _syncPreferences.pending =
          completion.preservePending ||
          _changeGeneration != completion.operation.generation;
    }
    completion.operation = completion.operation.copyWith(
      commitState: _lastCommitState,
      followUpComplete:
          completion.resume == null &&
          _lastCommitState != DataSyncCommitState.recoveryRequired,
    );
    _ownedOperation = completion.operation;
    _syncPreferences.pendingOperation = completion.operation.toJson();
    if (!completion.preserveLastAttempt) {
      _syncPreferences.lastAttempt = _now.millisecondsSinceEpoch;
    }
    var saved = false;
    try {
      if (completion.settingsPending) {
        await _persistConfiguration(
          settingsSaved: () => completion.settingsPending = false,
        );
      } else {
        await Future<void>.sync(_persistState);
      }
      saved = true;
    } catch (error, stack) {
      _appendDiagnostic(failures, 'save sync receipt', error, stack);
    }
    if (_lastCommitState == DataSyncCommitState.recoveryRequired) {
      if (failures.isEmpty) {
        failures.add((
          stage: 'recover sync operation',
          error: StateError('Sync outcome requires recovery'),
          stack: StackTrace.current,
        ));
      }
      _recoveryFailure = completion.resume == null
          ? DataSyncFailure(
              commitState: _lastCommitState,
              failures: failures,
              recoveryPath: completion.operation.recoveryPath,
            )
          : null;
    } else if (saved &&
        completion.resume == null &&
        !completion.configurationPending &&
        completion.restoreConfiguration == null) {
      // Settings and the terminal receipt have settled while the marker was
      // present. Only now may the durable recovery evidence be removed.
      var resolved = false;
      try {
        await _resolveCompletionReceipt(completion);
        if (completion.operation.version >= 4) {
          final content =
              _content ??
              (throw StateError('Sync content recovery is unavailable'));
          final generation = _changeGeneration;
          final state = await _trackRecoveryIo(
            'confirm synchronized content',
            () => content.finish(completion.operation, _lastCommitState),
          );
          if (state != DataSyncContentState.unknown) {
            _syncPreferences.pending =
                state == DataSyncContentState.changed ||
                _changeGeneration != generation;
          }
        }
        resolved = true;
      } catch (error, stack) {
        _retainRecoveryIoFailure('read import receipt', error, stack);
        _appendDiagnostic(failures, 'read import receipt', error, stack);
      }
      if (resolved) {
        _syncPreferences.pendingOperation = null;
        try {
          await Future<void>.sync(_persistState);
          completion.markerCleared = true;
        } catch (error, stack) {
          _syncPreferences.pendingOperation = completion.operation.toJson();
          _appendDiagnostic(failures, 'clear sync receipt', error, stack);
        }
      }
    }
    if (completion.markerCleared) {
      await _acknowledgeCompletion(completion, failures);
    }
    final Res<bool> result;
    if (failures.isEmpty) {
      result = const Res(true);
    } else if (original != null &&
        original.error &&
        (original.failure is! DataSyncFailure ||
            (original.failure! as DataSyncFailure).commitState ==
                _lastCommitState) &&
        failures.length ==
            (original.failure is DataSyncFailure
                ? (original.failure as DataSyncFailure).failures.length
                : 1)) {
      result = original;
    } else {
      result = Res.failure(
        DataSyncFailure(
          commitState: _lastCommitState,
          failures: failures,
          recoveryPath: completion.operation.recoveryPath,
        ),
      );
    }
    _lastError = result.errorMessage;
    return result;
  }

  Future<void> _resolveCompletionReceipt(_SyncCompletion completion) async {
    if (completion.operation.direction == DataSyncDirection.upload &&
        completion.operation.version >= 3) {
      if (completion.receiptResolved) return;
      final state = await _trackRecoveryIo(
        'read upload receipt',
        () => _uploadRecovery!.readTerminalUploadReceipt(
          _operationEndpoint(completion.operation),
          completion.operation.id,
        ),
      );
      if (state == null || state != completion.operation.commitState) {
        throw StateError('Missing or inconsistent terminal upload receipt');
      }
      completion.receiptId = completion.operation.id;
      completion.receiptResolved = true;
      _recoveryIoFailure = null;
      return;
    }
    final recovery = _importRecovery;
    if (completion.receiptResolved ||
        recovery == null ||
        completion.operation.direction != DataSyncDirection.download) {
      return;
    }
    final matches = (await _readImportReceipts())
        .where((receipt) => receipt.syncOperationId == completion.operation.id)
        .toList();
    if (matches.length > 1 ||
        (matches.isEmpty &&
            completion.operation.commitState == DataSyncCommitState.applied)) {
      throw StateError('Missing or ambiguous terminal import receipt');
    }
    if (matches.isNotEmpty) {
      final receipt = matches.single;
      if (receipt.commitState != completion.operation.commitState) {
        throw StateError('Import receipt disagrees with sync commit state');
      }
      if (receipt.commitState == DataSyncCommitState.applied &&
          !receipt.hasValidCommitTime) {
        throw StateError('Invalid applied import timestamp');
      }
      completion.receiptId = receipt.id;
    }
    completion.receiptResolved = true;
    _recoveryIoFailure = null;
  }

  Future<Res<bool>> _acknowledgeCompletion(
    _SyncCompletion completion,
    List<DataSyncDiagnostic> failures,
  ) async {
    try {
      final receiptId = completion.receiptId;
      if (receiptId != null) {
        if (completion.operation.direction == DataSyncDirection.upload) {
          await _trackRecoveryIo(
            'acknowledge upload receipt',
            () => _uploadRecovery!.acknowledgeUpload(receiptId),
          );
        } else {
          await _acknowledgeReceipt(receiptId);
        }
      }
      if (completion.operation.version >= 4) {
        final content =
            _content ??
            (throw StateError('Sync content recovery is unavailable'));
        await _trackRecoveryIo(
          'acknowledge synchronized content',
          () => content.acknowledge(completion.operation.id),
        );
      }
      _recoveryIoFailure = null;
      _completion = null;
      _ownedOperation = null;
    } catch (error, stack) {
      _retainRecoveryIoFailure('acknowledge import receipt', error, stack);
      _appendDiagnostic(failures, 'acknowledge import receipt', error, stack);
    }
    final result = failures.isEmpty
        ? const Res<bool>(true)
        : Res<bool>.failure(
            DataSyncFailure(
              commitState: completion.operation.commitState,
              failures: failures,
            ),
          );
    _lastError = result.errorMessage;
    return result;
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
        syncOperationId: _ownedOperation?.id,
      );
      _lastCommitState = DataSyncCommitState.applied;
      Log.info("Upload Data", "Data uploaded successfully");
      return const Res(true);
    } catch (e, s) {
      _captureTransferFailure(e);
      Log.error("Upload Data", e, s);
      _lastError = e.toString();
      return Res.fromException(e, s);
    } finally {
      if (identical(_transferScope, scope)) _transferScope = null;
      scope.dispose();
    }
  }

  Future<Res<bool>> _downloadNow({bool force = false}) async {
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
      final applied = await _dataTransfer.download(
        config,
        force: force,
        scope: scope,
        syncOperationId: _ownedOperation?.id,
        publishImported: _publishImported,
      );
      _lastCommitState = applied
          ? DataSyncCommitState.applied
          : DataSyncCommitState.notApplied;
      Log.info(
        "Data Sync",
        applied ? "Data downloaded successfully" : "No new data to download",
      );
      return const Res(true);
    } catch (e, s) {
      _captureTransferFailure(e);
      Log.error("Data Sync", e, s);
      _lastError = e.toString();
      return Res.fromException(e, s);
    } finally {
      if (identical(_transferScope, scope)) _transferScope = null;
      scope.dispose();
    }
  }

  void _captureTransferFailure(Object error) {
    if (error is DataSyncFailure) {
      _lastCommitState = error.commitState;
      if (error is DataSyncTransferFailure) _transferResume = error.resume;
    }
  }
}

void _appendDiagnostic(
  List<DataSyncDiagnostic> failures,
  String stage,
  Object error,
  StackTrace stack,
) {
  if (error is DataSyncFailure) {
    failures.addAll(error.failures);
  } else {
    failures.add((stage: stage, error: error, stack: stack));
  }
}

void _appendFailure(
  List<DataSyncDiagnostic> failures,
  String stage,
  Res<bool> result,
) {
  if (!result.error) return;
  final failure = result.failure;
  if (failure is DataSyncFailure) {
    failures.addAll(failure.failures);
  } else {
    failures.add((
      stage: stage,
      error: failure?.cause ?? StateError(result.errorMessage!),
      stack: failure?.stackTrace ?? StackTrace.current,
    ));
  }
}
