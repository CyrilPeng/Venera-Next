/// Preserve the legacy rule: a three-string WebDAV tuple enables auto sync.
/// Persist before startup can finish; a failed save must remain retryable.
Future<void> migrateLegacyAutoSync({
  required Map<String, dynamic> implicitData,
  required Object? webdav,
  required Future<void> Function() persist,
}) async {
  const key = 'webdavAutoSync';
  if (implicitData[key] != null) return;
  final hadKey = implicitData.containsKey(key);
  final enabled =
      webdav is List &&
      webdav.length == 3 &&
      webdav.every((value) => value is String);
  implicitData[key] = enabled;
  try {
    await persist();
  } catch (_) {
    // Do not overwrite a different preference set while persistence was pending.
    if (implicitData[key] == enabled) {
      if (hadKey) {
        implicitData[key] = null;
      } else {
        implicitData.remove(key);
      }
    }
    rethrow;
  }
}
