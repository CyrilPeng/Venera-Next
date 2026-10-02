import 'sync_configuration.dart';

/// Adapts typed sync configuration to existing settings and implicit-data keys.
/// Persistence and transfer transaction ownership remain with DataSync.
class SyncPreferenceStore {
  const SyncPreferenceStore({
    required Object? Function(String) readSetting,
    required void Function(String, Object?) writeSetting,
    required Map<String, dynamic> Function() implicitData,
  }) : _readSetting = readSetting,
       _writeSetting = writeSetting,
       _implicitData = implicitData;

  final Object? Function(String) _readSetting;
  final void Function(String, Object?) _writeSetting;
  final Map<String, dynamic> Function() _implicitData;

  int get lastSyncTime => (_readSetting('lastSyncTime') as int?) ?? 0;

  SyncConfiguration get configuration =>
      SyncConfiguration.read(_readSetting, (key) => _implicitData()[key]);

  bool get pending => _implicitData()['webdavSyncPending'] == true;
  set pending(bool value) => _implicitData()['webdavSyncPending'] = value;

  int? get lastAttempt {
    final value = _implicitData()['webdavSyncLastAttempt'];
    return value is int ? value : null;
  }

  set lastAttempt(int? value) =>
      _implicitData()['webdavSyncLastAttempt'] = value;

  static const _scheduleKeys = [
    'webdavSyncMode',
    'webdavAutoSync',
    'webdavSyncIntervalMinutes',
    'webdavSyncLastAttempt',
    'webdavSyncPending',
  ];

  SyncPreferenceCheckpoint capture() => SyncPreferenceCheckpoint._(
    _readSetting('webdav'),
    _readSetting('disableSyncFields'),
    {for (final key in _scheduleKeys) key: _implicitData()[key]},
  );

  void restore(SyncPreferenceCheckpoint checkpoint) {
    _writeSetting('webdav', checkpoint._connection);
    _writeSetting('disableSyncFields', checkpoint._excludedFields);
    for (final entry in checkpoint._schedule.entries) {
      if (entry.value == null) {
        _implicitData().remove(entry.key);
      } else {
        _implicitData()[entry.key] = entry.value;
      }
    }
  }

  void applyDraft(List<String> connection, String excludedFields) {
    _writeSetting('webdav', List<String>.of(connection));
    _writeSetting('disableSyncFields', excludedFields);
  }

  void setSchedule(DataSyncMode mode, int minutes) {
    _implicitData()['webdavSyncMode'] = mode.name;
    _implicitData()['webdavAutoSync'] = mode != DataSyncMode.manual;
    _implicitData()['webdavSyncIntervalMinutes'] =
        SyncConfiguration.normalizeInterval(minutes);
  }
}

/// Raw rollback values deliberately bypass normalization to preserve old data.
class SyncPreferenceCheckpoint {
  SyncPreferenceCheckpoint._(
    this._connection,
    this._excludedFields,
    this._schedule,
  );
  final Object? _connection;
  final Object? _excludedFields;
  final Map<String, Object?> _schedule;
}
