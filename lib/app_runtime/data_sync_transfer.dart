import 'dart:io';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/features/sync/sync.dart'
    show exportAppData, importAppData;
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

DataSyncTransfer createDataSyncTransfer() => WebDavDataSyncTransfer(
  participant: _ApplicationSyncParticipant(),
  openRemote: WebDavDataSyncRemote.new,
);

class _ApplicationSyncParticipant implements DataSyncParticipant {
  @override
  int? get version => appdata.settings['dataVersion'] as int?;

  @override
  String get cachePath => App.cachePath;

  @override
  Future<int> prepareUploadVersion() async {
    appdata.settings['dataVersion']++;
    await appdata.saveData(false);
    return appdata.settings['dataVersion'] as int;
  }

  @override
  Future<File> exportData(bool excludeFields) => exportAppData(excludeFields);

  @override
  Future<bool> importData(File file) async {
    await importAppData(file, true);
    return true;
  }

  @override
  void notifyImported() {
    HistoryManager().notifyChanges();
    LocalFavoritesManager().notifyChanges();
    ImageFavoriteManager().notifyChanges();
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async {
    appdata.settings['lastSyncTime'] = milliseconds;
    await appdata.saveData(false);
  }
}
