/// Stored names are part of the existing app-data sync protocol.
enum DataSyncMode { manual, realtime, scheduled }

class SyncConnection {
  const SyncConnection(
    this.url,
    this.user,
    this.password, {
    this.isEmpty = false,
  });
  final bool isEmpty;
  final String url;
  final String user;
  final String password;

  static SyncConnection? parse(Object? value) {
    if (value is! List) return null;
    if (value.isEmpty) return const SyncConnection('', '', '', isEmpty: true);
    if (value.length != 3 || value.whereType<String>().length != 3) return null;
    return SyncConnection(
      value[0] as String,
      value[1] as String,
      value[2] as String,
    );
  }
}

/// A read-only interpretation of legacy settings. Reading never repairs storage.
class SyncConfiguration {
  const SyncConfiguration({
    required this.connection,
    required this.excludedFields,
    required this.mode,
    required this.intervalMinutes,
  });

  static const intervalOptions = [5, 15, 30, 60, 180, 360];
  static int normalizeInterval(Object? value) =>
      value is int && intervalOptions.contains(value) ? value : 30;

  factory SyncConfiguration.read(
    Object? Function(String) settings,
    Object? Function(String) implicit,
  ) {
    final storedMode = implicit('webdavSyncMode');
    final mode = switch (storedMode) {
      'manual' => DataSyncMode.manual,
      'realtime' => DataSyncMode.realtime,
      'scheduled' => DataSyncMode.scheduled,
      _ =>
        implicit('webdavAutoSync') == true
            ? DataSyncMode.realtime
            : DataSyncMode.manual,
    };
    final fields = settings('disableSyncFields');
    return SyncConfiguration(
      connection: SyncConnection.parse(settings('webdav')),
      excludedFields: fields is String ? fields : '',
      mode: mode,
      intervalMinutes: normalizeInterval(implicit('webdavSyncIntervalMinutes')),
    );
  }

  final SyncConnection? connection;
  final String excludedFields;
  final DataSyncMode mode;
  final int intervalMinutes;
}
