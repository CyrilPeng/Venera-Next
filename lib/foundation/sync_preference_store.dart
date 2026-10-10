import 'sync_configuration.dart';

/// Adapts typed sync configuration to existing settings and implicit-data keys.
/// Persistence and transfer transaction ownership remain with DataSyncController.
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

  int get lastSyncTime => _readTimestamp(_readSetting('lastSyncTime')) ?? 0;

  SyncConfiguration get configuration =>
      SyncConfiguration.read(_readSetting, (key) => _implicitData()[key]);

  bool get pending => _implicitData()['webdavSyncPending'] == true;
  set pending(bool value) => _implicitData()['webdavSyncPending'] = value;

  /// Keep malformed persisted records visible for the operation decoder.
  Object? get pendingOperation => _implicitData()['webdavSyncOperation'];
  set pendingOperation(Object? value) {
    if (value == null) {
      _implicitData().remove('webdavSyncOperation');
    } else {
      _implicitData()['webdavSyncOperation'] = value;
    }
  }

  int? get lastAttempt =>
      _readTimestamp(_implicitData()['webdavSyncLastAttempt']);

  static int? _readTimestamp(Object? value) {
    if (value is! int || value < 0) return null;
    try {
      DateTime.fromMillisecondsSinceEpoch(value);
      return value;
    } on ArgumentError {
      return null;
    }
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
    _copyConfigurationValue(_readSetting('webdav')),
    _copyConfigurationValue(_readSetting('disableSyncFields')),
    {for (final key in _scheduleKeys) key: _implicitData()[key]},
  );

  void restore(SyncPreferenceCheckpoint checkpoint) {
    _writeSetting('webdav', _copyConfigurationValue(checkpoint._connection));
    _writeSetting(
      'disableSyncFields',
      _copyConfigurationValue(checkpoint._excludedFields),
    );
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

Object? _copyConfigurationValue(Object? value) => switch (value) {
  List<String>() => List<String>.of(value),
  List() => value.map(_copyConfigurationValue).toList(),
  Map() => value.map(
    (key, item) => MapEntry(key, _copyConfigurationValue(item)),
  ),
  _ => value,
};

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

  Map<String, Object?> toJson() => {
    'connection': _copyConfigurationValue(_connection),
    'excludedFields': _copyConfigurationValue(_excludedFields),
    'schedule': _copyConfigurationValue(_schedule),
  };

  factory SyncPreferenceCheckpoint.fromJson(Object? value) {
    if (value is! Map ||
        !value.containsKey('connection') ||
        !value.containsKey('excludedFields') ||
        value['schedule'] is! Map) {
      throw const FormatException('Invalid sync configuration checkpoint');
    }
    final schedule = value['schedule'] as Map;
    if (schedule.length != SyncPreferenceStore._scheduleKeys.length ||
        SyncPreferenceStore._scheduleKeys.any(
          (key) => !schedule.containsKey(key),
        )) {
      throw const FormatException('Invalid sync schedule checkpoint');
    }
    return SyncPreferenceCheckpoint._(
      _copyConfigurationValue(value['connection']),
      _copyConfigurationValue(value['excludedFields']),
      {
        for (final key in SyncPreferenceStore._scheduleKeys)
          key: _copyConfigurationValue(schedule[key]),
      },
    );
  }
}
