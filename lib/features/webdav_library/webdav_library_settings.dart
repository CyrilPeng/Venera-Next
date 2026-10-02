import 'webdav_library_config.dart';

/// Typed view of the legacy settings keys. Reading never repairs stored data.
class WebDavLibrarySettings {
  const WebDavLibrarySettings({
    required this.connection,
    required this.autoSync,
    required this.intervalMinutes,
  });

  final WebDavLibraryConfig connection;
  final bool autoSync;
  final int intervalMinutes;

  factory WebDavLibrarySettings.read(Object? Function(String) readValue) {
    final credentials = readValue('webdavComicLibrary');
    final valid =
        credentials is List &&
        credentials.length == 3 &&
        credentials.every((value) => value is String);
    final path = readValue('webdavComicLibraryPath');
    final interval = readValue('webdavComicLibrarySyncIntervalMinutes');
    final rounded = interval is num && interval.isFinite ? interval.round() : 0;
    return WebDavLibrarySettings(
      connection: WebDavLibraryConfig(
        url: valid ? credentials[0] as String : '',
        user: valid ? credentials[1] as String : '',
        pass: valid ? credentials[2] as String : '',
        remotePath: path is String ? path : '/venera_comics/',
      ),
      // Preserve the scheduler's opt-in rule for missing/malformed values.
      autoSync: readValue('webdavComicLibraryAutoSync') == true,
      intervalMinutes: rounded > 0 ? rounded : 360,
    );
  }

  Map<String, Object> toSettings() => {
    'webdavComicLibrary':
        !connection.isValid &&
            connection.user.isEmpty &&
            connection.pass.isEmpty
        ? <String>[]
        : [connection.url, connection.user, connection.pass],
    'webdavComicLibraryPath': connection.remotePath,
    'webdavComicLibraryAutoSync': autoSync,
    'webdavComicLibrarySyncIntervalMinutes': intervalMinutes,
  };
}

/// Persistence and runtime invalidation are supplied by the composition owner.
/// The persistence callback owns storage failure/rollback semantics.
class WebDavLibrarySettingsStore {
  WebDavLibrarySettingsStore({
    required Object? Function(String) readValue,
    required Future<void> Function(Map<String, Object>) persist,
    required void Function(WebDavLibraryConfig) onConnectionChanged,
  }) : _readValue = readValue,
       _persist = persist,
       _onConnectionChanged = onConnectionChanged;

  final Object? Function(String) _readValue;
  final Future<void> Function(Map<String, Object>) _persist;
  final void Function(WebDavLibraryConfig) _onConnectionChanged;

  WebDavLibrarySettings read() => WebDavLibrarySettings.read(_readValue);

  Future<void> save(WebDavLibrarySettings configuration) async {
    final previous = read().connection;
    await _persist(configuration.toSettings());
    if (previous.connectionKey != configuration.connection.connectionKey) {
      _onConnectionChanged(previous);
    }
  }
}
