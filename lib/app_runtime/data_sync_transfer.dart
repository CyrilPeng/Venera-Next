import 'package:venera_next/network/request_scope.dart';
import 'dart:io';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/features/sync/app_data_transfer.dart'
    show exportSyncAppData, importSyncAppData;
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/network/webdav.dart';

WebDavDataSyncTransfer createDataSyncTransfer({
  DataSyncRemote Function(WebDavEndpoint)? openRemote,
  DataSyncImportRecovery? importRecovery,
}) => WebDavDataSyncTransfer(
  participant: _ApplicationSyncParticipant(),
  openRemote: openRemote ?? WebDavDataSyncRemote.new,
  uploadJournalPath: () => App.dataPath,
  readImportCommitTime: (operationId) async {
    final recovery = importRecovery ?? createDataSyncImportRecovery();
    final matches = (await recovery.readReceipts())
        .where((receipt) => receipt.syncOperationId == operationId)
        .toList();
    if (matches.length != 1 ||
        matches.single.commitState != DataSyncCommitState.applied ||
        !matches.single.hasValidCommitTime) {
      throw StateError('Missing or ambiguous applied import timestamp');
    }
    return matches.single.committedAt!;
  },
);

DataSyncImportRecovery createDataSyncImportRecovery() =>
    _ApplicationImportRecovery(_ApplicationSyncParticipant());

class _ApplicationImportRecovery implements DataSyncImportRecovery {
  _ApplicationImportRecovery(this.participant);
  final DataSyncParticipant participant;

  @override
  Future<List<DataSyncImportReceipt>> readReceipts() async {
    final journal = AppDataImportJournal.open(App.dataPath);
    try {
      return [
        for (final receipt in journal.receipts)
          DataSyncImportReceipt(
            id: receipt.id,
            syncOperationId: receipt.syncOperationId,
            commitState: receipt.commitState,
            committedAt: receipt.committedAt,
          ),
      ];
    } finally {
      journal.close();
    }
  }

  @override
  Future<void> acknowledge(String receiptId) async {
    final journal = AppDataImportJournal.open(App.dataPath);
    try {
      await journal.acknowledge(receiptId);
    } finally {
      journal.close();
    }
  }

  @override
  void notifyImported() => participant.notifyImported();
  @override
  Future<void> recordSyncTime(int milliseconds) =>
      participant.recordSyncTime(milliseconds);
}

class _ApplicationSyncParticipant implements DataSyncParticipant {
  @override
  int get version =>
      SyncConfiguration.requireDataVersion(appdata.settings['dataVersion']);

  @override
  String get cachePath => App.cachePath;

  @override
  Future<int> prepareUploadVersion() => appdata.updateSettings((settings) {
    final version =
        SyncConfiguration.requireDataVersion(settings['dataVersion']) + 1;
    settings['dataVersion'] = version;
    return version;
  }, sync: false);

  @override
  Future<void> exportData(
    bool excludeFields,
    File destination, {
    String? syncOperationId,
  }) => exportSyncAppData(
    excludeFields: excludeFields,
    destination: destination,
    syncOperationId: syncOperationId,
  );

  @override
  Future<DataSyncCommitState> importData(
    File file, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) => importSyncAppData(
    file,
    checkActive: scope.check,
    publishImported: publishImported,
    syncOperationId: syncOperationId,
  );

  @override
  void notifyImported() {
    HistoryManager().notifyChanges();
    LocalFavoritesManager().notifyChanges();
    ImageFavoriteManager().notifyChanges();
  }

  @override
  Future<void> recordSyncTime(int milliseconds) =>
      appdata.updateSettings((settings) {
        settings['lastSyncTime'] = milliseconds;
      }, sync: false);
}
