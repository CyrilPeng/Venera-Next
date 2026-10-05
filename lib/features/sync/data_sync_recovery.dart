import 'data_sync_commit.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/webdav.dart';

/// A terminal local import record. Reading it must never replace live files.
class DataSyncImportReceipt {
  const DataSyncImportReceipt({
    required this.id,
    required this.syncOperationId,
    required this.commitState,
    required this.committedAt,
  });

  final String id;
  final String? syncOperationId;
  final DataSyncCommitState commitState;
  final int? committedAt;

  /// Keep persisted timestamps within the range accepted by DateTime.
  bool get hasValidCommitTime => isValidDataSyncCommitTime(committedAt);
}

/// Bootstrap owns filesystem recovery, before stores are opened. This port only
/// reads terminal evidence, publishes an applied import and acknowledges its
/// owned recovery files after the controller's durable marker has been removed.
abstract interface class DataSyncImportRecovery {
  Future<List<DataSyncImportReceipt>> readReceipts();
  Future<void> acknowledge(String receiptId);
  void notifyImported();
  Future<void> recordSyncTime(int milliseconds);
}

/// Upload recovery is available only when the transfer durably records intent
/// before any remote write. Endpoints always come from the original operation.
abstract interface class DataSyncUploadRecovery {
  Future<DataSyncCommitState> recoverUpload(
    WebDavEndpoint connection, {
    required String syncOperationId,
    required RequestScope scope,
  });

  Future<DataSyncCommitState?> readTerminalUploadReceipt(
    WebDavEndpoint connection,
    String syncOperationId,
  );

  Future<List<String>> listTerminalUploadOperations();
  Future<void> acknowledgeUpload(String syncOperationId);
}
