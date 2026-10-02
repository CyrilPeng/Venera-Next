import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/app_sync_preferences.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'data_sync_controller.dart';
import 'data_sync_transfer.dart';

export 'data_sync_controller.dart' show DataSyncStatusSnapshot;
export 'package:venera_next/foundation/sync_configuration.dart'
    show DataSyncMode;

DataSyncTransfer Function()? _dataSyncTransferFactory;
void configureDataSyncTransferFactory(DataSyncTransfer Function() factory) {
  _dataSyncTransferFactory = factory;
}

final _syncPreferences = createAppSyncPreferences(appdata);

/// Transitional application owner. New isolated consumers use DataSyncController.
class DataSync extends DataSyncController {
  DataSync._([DataSyncTransfer? transfer])
    : super(
        preferences: _syncPreferences,
        transfer: () =>
            transfer ??
            (_dataSyncTransferFactory ??
                (() => throw StateError(
                  'Data sync transfer is not configured',
                )))(),
        saveSettings: () => appdata.saveData(false),
        persistImplicit: appdata.writeImplicitData,
        observeChanges: _observeApplicationChanges,
        now: () => debugNow?.call() ?? DateTime.now(),
      );

  factory DataSync.withTransfer(DataSyncTransfer transfer) =>
      DataSync._(transfer);
  static DataSync? instance;
  factory DataSync() => instance ?? (instance = DataSync._());

  static DataSyncMode get mode => _syncPreferences.configuration.mode;
  static int get intervalMinutes =>
      _syncPreferences.configuration.intervalMinutes;
  static const intervalOptions = SyncConfiguration.intervalOptions;

  @visibleForTesting
  static DateTime Function()? debugNow;
  @visibleForTesting
  static Future<Res<bool>> Function()? debugUploadOverride;
  @visibleForTesting
  static Future<Res<bool>> Function()? debugDownloadOverride;
  @visibleForTesting
  static void resetForTesting() {
    instance?.dispose();
    instance = null;
    debugUploadOverride = null;
    debugDownloadOverride = null;
    debugNow = null;
  }

  @override
  Future<Res<bool>> uploadNow() =>
      debugUploadOverride?.call() ?? super.uploadNow();
  @override
  Future<Res<bool>> downloadNow() =>
      debugDownloadOverride?.call() ?? super.downloadNow();
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
