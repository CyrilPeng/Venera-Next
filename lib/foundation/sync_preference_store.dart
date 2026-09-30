import 'appdata.dart';
import 'sync_configuration.dart';

/// Adapts typed sync configuration to existing settings and implicit-data keys.
/// Persistence and transfer transaction ownership remain with DataSync.
class SyncPreferenceStore {
  const SyncPreferenceStore(this.data);
  final Appdata data;

  SyncConfiguration get configuration => SyncConfiguration.read(
    (key) => data.settings[key],
    (key) => data.implicitData[key],
  );

  bool get pending => data.implicitData['webdavSyncPending'] == true;
  set pending(bool value) => data.implicitData['webdavSyncPending'] = value;

  int? get lastAttempt {
    final value = data.implicitData['webdavSyncLastAttempt'];
    return value is int ? value : null;
  }

  set lastAttempt(int? value) =>
      data.implicitData['webdavSyncLastAttempt'] = value;

  static const _scheduleKeys = [
    'webdavSyncMode',
    'webdavAutoSync',
    'webdavSyncIntervalMinutes',
    'webdavSyncLastAttempt',
    'webdavSyncPending',
  ];

  SyncPreferenceCheckpoint capture() => SyncPreferenceCheckpoint._(
    data.settings['webdav'],
    data.settings['disableSyncFields'],
    {for (final key in _scheduleKeys) key: data.implicitData[key]},
  );

  void restore(SyncPreferenceCheckpoint checkpoint) {
    data.settings['webdav'] = checkpoint._connection;
    data.settings['disableSyncFields'] = checkpoint._excludedFields;
    for (final entry in checkpoint._schedule.entries) {
      if (entry.value == null) {
        data.implicitData.remove(entry.key);
      } else {
        data.implicitData[entry.key] = entry.value;
      }
    }
  }

  void applyDraft(List<String> connection, String excludedFields) {
    data.settings['webdav'] = List<String>.of(connection);
    data.settings['disableSyncFields'] = excludedFields;
  }

  void setSchedule(DataSyncMode mode, int minutes) {
    data.implicitData['webdavSyncMode'] = mode.name;
    data.implicitData['webdavAutoSync'] = mode != DataSyncMode.manual;
    data.implicitData['webdavSyncIntervalMinutes'] =
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
