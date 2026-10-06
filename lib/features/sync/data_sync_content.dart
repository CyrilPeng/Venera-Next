import 'data_sync_commit.dart';
import 'data_sync_operation.dart';

enum DataSyncContentState { unknown, clean, changed }

/// Persistent comparisons use the content actually exported/imported. The
/// controller's in-memory generation remains useful for scheduling, but is not
/// evidence that a restarted process has no unsynchronized writes.
abstract interface class DataSyncContent {
  /// Requires the service's directory ownership. Returns true only when an
  /// active download has no import intent and therefore cannot have applied.
  Future<bool> recover(DataSyncOperation? activeOperation);
  Future<DataSyncContentState> inspect(
    List<String> connection,
    String excludedFields,
  );
  Future<void> prepare(DataSyncOperation operation, {required bool automatic});
  Future<DataSyncContentState> finish(
    DataSyncOperation operation,
    DataSyncCommitState state,
  );
  Future<void> acknowledge(String operationId);
  Future<void> close();
}

class DataSyncContentConflict implements Exception {
  const DataSyncContentConflict();
  @override
  String toString() =>
      'Local data changed while downloading. Upload local changes before downloading again.';
}

class DataSyncBaselineUnavailable implements Exception {
  const DataSyncBaselineUnavailable();
  @override
  String toString() =>
      'Complete an upload or download a newer backup to resume automatic sync.';
}
