import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'data_sync_transfer.dart';
import 'data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/foundation/app.dart';

/// Construction is inert. The application owns start/stop/dispose.
DataSyncController createApplicationDataSync({
  DataSyncTransfer Function()? transfer,
  DataSyncImportRecovery? importRecovery,
  DataSyncUploadRecovery? uploadRecovery,
}) {
  final recovery = importRecovery ?? createDataSyncImportRecovery();
  final defaultTransfer = transfer == null
      ? createDataSyncTransfer(importRecovery: recovery)
      : null;
  return DataSyncController(
    preferences: createAppSyncPreferences(appdata),
    transfer: transfer ?? () => defaultTransfer!,
    importRecovery: recovery,
    uploadRecovery: uploadRecovery ?? defaultTransfer,
    content: ApplicationDataSyncContent(),
    ownership: SqliteDataSyncOwnership(() => App.dataPath),
    saveSettings: () => appdata.saveData(false),
    persistImplicit: appdata.writeImplicitData,
    observeChanges: _observeApplicationChanges,
  );
}

void Function() _observeApplicationChanges(void Function() changed) {
  final favorites = LocalFavoritesManager();
  final sources = ComicSourceManager();
  favorites.addListener(changed);
  try {
    sources.addListener(changed);
    appdata.registerSyncDataRequestHandler(changed);
  } catch (_) {
    favorites.removeListener(changed);
    sources.removeListener(changed);
    rethrow;
  }
  return () {
    appdata.registerSyncDataRequestHandler(null);
    favorites.removeListener(changed);
    sources.removeListener(changed);
  };
}
