import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'data_sync_transfer.dart';

/// Construction is inert. The application owns start/stop/dispose.
DataSyncController createApplicationDataSync() => DataSyncController(
  preferences: createAppSyncPreferences(appdata),
  transfer: createDataSyncTransfer,
  saveSettings: () => appdata.saveData(false),
  persistImplicit: appdata.writeImplicitData,
  observeChanges: _observeApplicationChanges,
);

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
