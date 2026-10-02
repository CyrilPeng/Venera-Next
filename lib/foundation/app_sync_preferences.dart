import 'appdata.dart';
import 'sync_preference_store.dart';

SyncPreferenceStore createAppSyncPreferences(Appdata data) =>
    SyncPreferenceStore(
      readSetting: (key) => data.settings[key],
      writeSetting: (key, value) => data.settings[key] = value,
      implicitData: () => data.implicitData,
    );
