import 'dart:convert';
import 'dart:isolate';

import 'package:venera_next/features/comic_source/source_transaction_journal.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_content_fingerprint.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_recovery.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';

/// Application composition holds the existing writer barrier while capturing
/// content. The protocol/journal below this adapter has no Flutter dependency.
class ApplicationDataSyncContent implements DataSyncContent {
  final _recovery = DataSyncContentRecovery();
  final _pendingClose = <void Function()>[];

  void _closeResource(void Function() close) {
    try {
      close();
    } catch (_) {
      _pendingClose.add(close);
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final failures = <DataSyncDiagnostic>[];
    for (final close in [_recovery.close, ..._pendingClose]) {
      try {
        close();
        _pendingClose.remove(close);
      } catch (error, stack) {
        failures.add((
          stage: 'release sync content resource',
          error: error,
          stack: stack,
        ));
      }
    }
    if (failures.isNotEmpty) {
      throw DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        failures: failures,
      );
    }
  }

  @override
  Future<bool> recover(DataSyncOperation? operation) =>
      AppDataOperations.instance.run(() async {
        await close();
        return _recovery.recover(App.dataPath, operation);
      });
  DataSyncContentScope _scope(List<String> connection, String excluded) =>
      DataSyncContentScope(
        endpoint: dataSyncEndpointFingerprint(connection),
        excludedFields: excluded,
        archiveSyncEnabled: appdata.settings['backupWebdavSyncEnabled'] == true,
      );

  Future<String> _capture(
    String path,
    DataSyncContentScope scope, {
    bool importGuard = false,
  }) async {
    await SourceTransactionJournal.checkReadyForTransfer(path);
    await HistoryManager.cache?.waitForAsyncWrites();
    final memory = jsonEncode(appdata.toJson());
    final hash = await Isolate.run(
      () => DataSyncContentFingerprint.capture(
        path,
        excludedFields: scope.excludedFields,
        archiveSyncEnabled: scope.archiveSyncEnabled,
        memorySettingsJson: memory,
        importGuard: importGuard,
      ),
    );
    if (App.dataPath != path) {
      throw StateError('Sync content directory changed');
    }
    return hash;
  }

  @override
  Future<DataSyncContentState> inspect(
    List<String> connection,
    String excludedFields,
  ) => AppDataOperations.instance.run(() async {
    final path = App.dataPath;
    final scope = _scope(connection, excludedFields);
    final current = await _capture(path, scope);
    final journal = DataSyncContentJournal.open(path);
    try {
      final baseline = journal.baseline(scope);
      return baseline == null
          ? DataSyncContentState.unknown
          : baseline == current
          ? DataSyncContentState.clean
          : DataSyncContentState.changed;
    } finally {
      _closeResource(journal.close);
    }
  });

  @override
  Future<void> prepare(
    DataSyncOperation operation, {
    required bool automatic,
  }) => AppDataOperations.instance.run(() async {
    final path = App.dataPath;
    final scope = _scope(operation.connection, operation.excludedFields);
    final current = await _capture(path, scope);
    final before =
        operation.direction == DataSyncDirection.download &&
            scope.hasImportOnlyFields
        ? await _capture(path, scope, importGuard: true)
        : current;
    final journal = DataSyncContentJournal.open(path);
    try {
      if (automatic && operation.direction == DataSyncDirection.download) {
        final baseline = journal.baseline(scope);
        if (baseline == null) throw const DataSyncBaselineUnavailable();
        if (baseline != current) throw const DataSyncContentConflict();
      }
      journal.begin(
        id: operation.id,
        direction: operation.direction.name,
        scope: scope,
        before: before,
      );
    } finally {
      _closeResource(journal.close);
    }
  });

  @override
  Future<DataSyncContentState> finish(
    DataSyncOperation operation,
    DataSyncCommitState state,
  ) => AppDataOperations.instance.run(() async {
    final path = App.dataPath;
    final journal = DataSyncContentJournal.open(path);
    try {
      final record =
          journal.lookup(operation.id) ??
          (throw StateError('Missing synchronized content evidence'));
      if (record.direction != operation.direction.name ||
          record.scope.endpoint !=
              dataSyncEndpointFingerprint(operation.connection) ||
          record.scope.excludedFields !=
              _scope(
                operation.connection,
                operation.excludedFields,
              ).excludedFields) {
        throw StateError('Sync content evidence belongs to another operation');
      }
      if (state == DataSyncCommitState.applied) {
        if (operation.direction == DataSyncDirection.upload) {
          final uploads = DataSyncUploadJournal.open(path);
          try {
            final receipt = uploads.lookup(operation.id);
            if (receipt == null ||
                !receipt.isTerminal ||
                receipt.commitState != state ||
                receipt.endpointFingerprint != record.scope.endpoint ||
                receipt.sha256 != record.archiveHash) {
              throw StateError(
                'Upload receipt does not match synchronized content',
              );
            }
          } finally {
            _closeResource(uploads.close);
          }
        } else {
          final imports = AppDataImportJournal.open(path);
          try {
            final matches = imports.receipts
                .where((receipt) => receipt.syncOperationId == operation.id)
                .toList();
            if (matches.length != 1 ||
                matches.single.commitState != state ||
                !isValidDataSyncCommitTime(matches.single.committedAt)) {
              throw StateError(
                'Import receipt does not match synchronized content',
              );
            }
          } finally {
            _closeResource(imports.close);
          }
        }
        journal.confirm(operation.id);
      } else if (state == DataSyncCommitState.notApplied) {
        // The controller has resolved the terminal transfer receipt before this
        // call. Recovery also checks all import intents, not just receipts.
        if (operation.direction == DataSyncDirection.download) {
          final imports = AppDataImportJournal.open(path);
          try {
            final matches = imports.receipts
                .where((receipt) => receipt.syncOperationId == operation.id)
                .toList();
            if (imports.containsSyncOperation(operation.id) &&
                (matches.length != 1 || matches.single.commitState != state)) {
              throw StateError('Import has no matching not-applied receipt');
            }
          } finally {
            _closeResource(imports.close);
          }
        } else {
          final uploads = DataSyncUploadJournal.open(path);
          try {
            final receipt = uploads.lookup(operation.id);
            if (receipt == null ||
                !receipt.isTerminal ||
                receipt.commitState != state ||
                receipt.endpointFingerprint != record.scope.endpoint) {
              throw StateError('Upload has no matching not-applied receipt');
            }
          } finally {
            _closeResource(uploads.close);
          }
        }
        journal.completeNotApplied(operation.id);
      }
      final scope = _scope(operation.connection, operation.excludedFields);
      final baseline = journal.baseline(scope);
      final current = await _capture(path, scope);
      return baseline == null
          ? DataSyncContentState.unknown
          : baseline == current
          ? DataSyncContentState.clean
          : DataSyncContentState.changed;
    } finally {
      _closeResource(journal.close);
    }
  });

  @override
  Future<void> acknowledge(String operationId) =>
      AppDataOperations.instance.run(() {
        final journal = DataSyncContentJournal.open(App.dataPath);
        try {
          journal.acknowledge(operationId);
        } finally {
          _closeResource(journal.close);
        }
      });
}
