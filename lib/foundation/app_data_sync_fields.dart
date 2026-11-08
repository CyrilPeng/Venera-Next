/// Fields retained locally by application-data imports. Keep content comparison
/// and import policy together so transport bookkeeping cannot create dirty data.
const appDataLocalFields = {
  'proxy',
  'authorizationRequired',
  'customImageProcessing',
  'webdav',
  'webdavProxyEnabled',
  'backupWebdav',
  'backupWebdavPath',
  'webdavComicLibrary',
  'webdavComicLibraryPath',
  'disableSyncFields',
  'deviceId',
  'lastSyncTime',
  ...appDataDeviceOnlyFields,
};

/// Device policies must not travel in portable backups or WebDAV uploads.
const appDataDeviceOnlyFields = {'windowsWindowHotkey', 'tvLowMemoryMode'};

const appDataOptionalArchiveFields = {'backupWebdav', 'backupWebdavPath'};

/// Keywords and their match options form one portable setting. Excluding either
/// half must also exclude the other in uploads, imports and content fingerprints.
const appDataKeywordOptionFields = {
  'blockedWords': 'blockedWordRules',
  'blockedCommentWords': 'blockedCommentWordRules',
};

const _linkedAppDataFields = {
  ...appDataKeywordOptionFields,
  'blockedWordRules': 'blockedWords',
  'blockedCommentWordRules': 'blockedCommentWords',
};

List<String> splitAppDataFields(String value) {
  final fields = value
      .split(',')
      .map((field) => field.trim())
      .where((field) => field.isNotEmpty)
      .toList();
  final linked = {for (final field in fields) ?_linkedAppDataFields[field]};
  return [...fields, ...linked.where((field) => !fields.contains(field))];
}
