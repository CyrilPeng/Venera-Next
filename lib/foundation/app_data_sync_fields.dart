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
};

const appDataOptionalArchiveFields = {'backupWebdav', 'backupWebdavPath'};

List<String> splitAppDataFields(String value) => value
    .split(',')
    .map((field) => field.trim())
    .where((field) => field.isNotEmpty)
    .toList();
