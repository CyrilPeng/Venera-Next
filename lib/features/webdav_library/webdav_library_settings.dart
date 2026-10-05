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

/// The composition owner persists a captured configuration and reconciles its
/// runtime effects with the actual published state, including partial failure.
class WebDavLibrarySettingsStore {
  WebDavLibrarySettingsStore({
    required Object? Function(String) readValue,
    required Future<void> Function(WebDavLibrarySettings) persist,
  }) : _readValue = readValue,
       _persist = persist;

  final Object? Function(String) _readValue;
  final Future<void> Function(WebDavLibrarySettings) _persist;

  WebDavLibrarySettings read() => WebDavLibrarySettings.read(_readValue);

  Future<void> save(WebDavLibrarySettings configuration) =>
      _persist(configuration);
}
