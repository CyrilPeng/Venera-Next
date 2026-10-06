import 'data_sync_archive_order.dart';
import 'data_sync_commit.dart';
import 'data_sync_recovery.dart';
import 'data_sync_remote_port.dart';
import 'data_sync_upload_journal.dart';
import 'data_sync_upload_executor.dart';
import 'dart:async';
import 'package:venera_next/network/request_scope.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';

import 'package:venera_next/network/webdav.dart';

export 'data_sync_remote_port.dart';

/// Application data participating in archive synchronization.
abstract interface class DataSyncParticipant {
  int? get version;
  String get cachePath;
  Future<int> prepareUploadVersion();
  Future<void> exportData(
    bool excludeFields,
    File destination, {
    String? syncOperationId,
  });

  /// Apply the archive while identifying only its own synchronous change
  /// publications. Independent local edits during import remain observable.
  Future<DataSyncCommitState> importData(
    File file, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  });
  void notifyImported();
  Future<void> recordSyncTime(int milliseconds);
}

abstract interface class DataSyncTransfer {
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  });

  /// False means no remote update was applied; pending local edits must survive.
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  });
}

class DataSyncArchiveNotFound implements Exception {
  const DataSyncArchiveNotFound();

  @override
  String toString() => 'No data file found';
}

/// The receipt survives failed follow-up work. Recovery reconciles an unresolved
/// upload using its original snapshot, or finishes remaining post-commit steps.
/// It never re-exports or repeats an already confirmed upload or import.
class DataSyncTransferFailure extends DataSyncFailure {
  DataSyncTransferFailure({
    required super.commitState,
    required super.failures,
    super.recoveryPath,
    this.resume,
  });

  final Future<DataSyncCommitState> Function(RequestScope)? resume;
}

class WebDavDataSyncTransfer
    implements DataSyncTransfer, DataSyncUploadRecovery {
  WebDavDataSyncTransfer({
    required DataSyncParticipant participant,
    required DataSyncRemote Function(WebDavEndpoint) openRemote,
    Future<int> Function(String syncOperationId)? readImportCommitTime,
    required String Function() uploadJournalPath,
    DateTime Function()? now,
  }) : _participant = participant,
       _openRemote = openRemote,
       _readImportCommitTime = readImportCommitTime,
       _uploadJournalPath = uploadJournalPath,
       _now = now ?? DateTime.now;

  final DataSyncParticipant _participant;
  final DataSyncRemote Function(WebDavEndpoint) _openRemote;
  final DateTime Function() _now;
  final Future<int> Function(String)? _readImportCommitTime;
  final String Function() _uploadJournalPath;

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) async {
    final id = syncOperationId ?? const Uuid().v4();
    final state = await _executeUpload(
      connection,
      id,
      scope,
      recover: false,
      excludeFields: excludeFields,
      acknowledge: syncOperationId == null,
    );
    if (state != DataSyncCommitState.applied) {
      throw DataSyncTransferFailure(
        commitState: state,
        failures: [
          (
            stage: 'upload',
            error: StateError('Upload did not apply'),
            stack: StackTrace.current,
          ),
        ],
      );
    }
  }

  String _fingerprint(WebDavEndpoint connection) => dataSyncEndpointFingerprint(
    [connection.url, connection.user, connection.password],
  );

  Future<DataSyncCommitState> _executeUpload(
    WebDavEndpoint connection,
    String id,
    RequestScope scope, {
    required bool recover,
    bool excludeFields = false,
    bool acknowledge = false,
  }) async {
    DataSyncUploadJournal? journal;
    try {
      scope.check();
      journal = DataSyncUploadJournal.open(_uploadJournalPath());
      final executor = DataSyncUploadExecutor(
        journal: journal,
        endpointFingerprint: _fingerprint(connection),
        openRemote: () => _openRemote(connection),
        prepareVersion: _participant.prepareUploadVersion,
        exportData: (destination) => _participant.exportData(
          excludeFields,
          destination,
          syncOperationId: id,
        ),
        recordSyncTime: _participant.recordSyncTime,
        now: _now,
      );
      final state = recover
          ? await executor.recover(id, scope)
          : await executor.upload(id, scope);
      if (acknowledge) await journal.acknowledge(id);
      return state;
    } catch (error, stack) {
      final failures = <DataSyncDiagnostic>[];
      _addDiagnostic(failures, 'upload journal', error, stack);
      Future<DataSyncCommitState>? resuming;
      DataSyncCommitState? completed;
      Future<DataSyncCommitState> resume(RequestScope nextScope) {
        if (completed case final state?) return Future.value(state);
        final active = resuming;
        if (active != null) return active;
        return resuming =
            _executeUpload(
                  connection,
                  id,
                  nextScope,
                  recover: true,
                  acknowledge: acknowledge,
                )
                .then((state) {
                  completed = state;
                  return state;
                })
                .whenComplete(() => resuming = null);
      }

      throw DataSyncTransferFailure(
        commitState: error is DataSyncFailure
            ? error.commitState
            : DataSyncCommitState.recoveryRequired,
        failures: failures,
        recoveryPath: error is DataSyncFailure ? error.recoveryPath : null,
        resume: resume,
      );
    } finally {
      journal?.close();
    }
  }

  @override
  Future<DataSyncCommitState> recoverUpload(
    WebDavEndpoint connection, {
    required String syncOperationId,
    required RequestScope scope,
  }) => _executeUpload(connection, syncOperationId, scope, recover: true);

  @override
  Future<DataSyncCommitState?> readTerminalUploadReceipt(
    WebDavEndpoint connection,
    String syncOperationId,
  ) async {
    final journal = DataSyncUploadJournal.open(_uploadJournalPath());
    try {
      final record = journal.lookup(syncOperationId);
      if (record == null) return null;
      if (record.endpointFingerprint != _fingerprint(connection)) {
        throw StateError(
          'Upload journal endpoint does not match original operation',
        );
      }
      return record.isTerminal ? record.commitState : null;
    } finally {
      journal.close();
    }
  }

  @override
  Future<List<String>> listTerminalUploadOperations() async {
    final journal = DataSyncUploadJournal.open(_uploadJournalPath());
    try {
      return [
        for (final record in journal.records)
          if (record.isTerminal) record.operationId,
      ];
    } finally {
      journal.close();
    }
  }

  @override
  Future<void> acknowledgeUpload(String syncOperationId) async {
    final journal = DataSyncUploadJournal.open(_uploadJournalPath());
    try {
      await journal.acknowledge(syncOperationId);
    } finally {
      journal.close();
    }
  }

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    void Function(void Function())? publishImported,
    String? syncOperationId,
  }) async {
    scope.check();
    final remote = _openRemote(connection);
    final closeRemote = _closeOnCancel(scope, remote);
    final pending = _TransferFinalization(
      participant: _participant,
      publishImported: publishImported,
      resolveImportTime:
          syncOperationId == null || _readImportCommitTime == null
          ? null
          : () => _readImportCommitTime(syncOperationId),
    );
    final failures = <DataSyncDiagnostic>[];
    Object? operationError;
    StackTrace? operationStack;
    try {
      final files = await remote.listNames();
      scope.check();
      files.sort((a, b) => compareDataSyncArchiveNames(b, a));
      final name = files.where((name) => name.endsWith('.venera')).firstOrNull;
      if (name == null) throw const DataSyncArchiveNotFound();
      final parts = name.split('-');
      final version = parts.length > 1
          ? int.tryParse(parts[1].split('.').first)
          : null;
      final current = _participant.version;
      if (version == null || current == null || version > current) {
        final temporary = pending.temporary = await Directory(
          _participant.cachePath,
        ).createTemp('data-sync-');
        scope.check();
        final archive = File('${temporary.path}/snapshot.venera');
        await remote.readToFile(name, archive.path);
        scope.check();
        try {
          pending.state = await _participant.importData(
            archive,
            scope: scope,
            publishImported: publishImported,
            syncOperationId: syncOperationId,
          );
        } on DataSyncFailure catch (error) {
          pending.state = error.commitState;
          pending.recoveryPath = error.recoveryPath;
          if (error is DataSyncImportFailure &&
              error.commitState == DataSyncCommitState.applied) {
            pending.importCleanup = error.resume;
          }
          rethrow;
        }
        if (pending.state == DataSyncCommitState.recoveryRequired) {
          throw StateError('Import recovery is required');
        }
      }
    } catch (error, stack) {
      operationError = error;
      operationStack = stack;
      _addDiagnostic(failures, 'transfer', error, stack);
    }
    if (pending.state == DataSyncCommitState.applied) {
      pending.markApplied(_now().millisecondsSinceEpoch, notify: true);
      // Commit is already established, including when importer cleanup failed.
      // Cancellation after it cannot suppress notifications or the sync marker.
      await pending.finishBusiness(remote, null, failures);
    }
    await pending.closeAndDelete(closeRemote, failures);
    pending.throwIfFailed(failures, operationError, operationStack);
    return pending.state == DataSyncCommitState.applied;
  }
}

/// Concrete unfinished steps for one transfer. Completed stages are removed so
/// even repeated finalization attempts cannot replay an upload/import or notify
/// again after a later timestamp/file failure.
class _TransferFinalization {
  _TransferFinalization({
    required this.participant,
    this.publishImported,
    this.resolveImportTime,
  });

  final DataSyncParticipant participant;
  final void Function(void Function())? publishImported;
  Future<int> Function()? resolveImportTime;
  DataSyncCommitState state = DataSyncCommitState.notApplied;
  String? recoveryPath;
  Directory? temporary;
  bool notifyPending = false;
  int? timePending;
  Future<DataSyncCommitState> Function()? importCleanup;
  Future<DataSyncCommitState>? _resuming;

  void markApplied(int timestamp, {bool notify = false}) {
    state = DataSyncCommitState.applied;
    timePending = timestamp;
    notifyPending = notify;
  }

  Future<void> finishBusiness(
    DataSyncRemote? remote,
    RequestScope? scope,
    List<DataSyncDiagnostic> failures,
  ) async {
    var stage = 'finish import';
    try {
      scope?.check();
      if (resolveImportTime case final resolve?) {
        stage = 'read import commit time';
        timePending = await resolve();
        resolveImportTime = null;
      }
      if (notifyPending) {
        stage = 'notify imported';
        final publish = publishImported;
        if (publish == null) {
          participant.notifyImported();
        } else {
          publish(participant.notifyImported);
        }
        notifyPending = false;
      }
      if (timePending case final timestamp?) {
        stage = 'record sync time';
        scope?.check();
        await participant.recordSyncTime(timestamp);
        timePending = null;
      }
    } catch (error, stack) {
      _addDiagnostic(failures, stage, error, stack);
    }
  }

  Future<void> closeAndDelete(
    Future<void> Function()? closeRemote,
    List<DataSyncDiagnostic> failures,
  ) async {
    if (closeRemote != null) {
      try {
        await closeRemote();
      } catch (error, stack) {
        _addDiagnostic(failures, 'remote close', error, stack);
      }
    }
    try {
      final directory = temporary;
      if (directory != null) {
        if (await directory.exists()) await directory.delete(recursive: true);
        temporary = null;
      }
    } catch (error, stack) {
      _addDiagnostic(failures, 'file cleanup', error, stack);
    }
  }

  void throwIfFailed(
    List<DataSyncDiagnostic> failures, [
    Object? originalError,
    StackTrace? originalStack,
  ]) {
    if (failures.isEmpty) return;
    // A sole pre-commit failure keeps its original identity and stack.
    if (state == DataSyncCommitState.notApplied &&
        originalError != null &&
        failures.length ==
            (originalError is DataSyncFailure
                ? originalError.failures.length
                : 1)) {
      Error.throwWithStackTrace(originalError, originalStack!);
    }
    final failure = DataSyncTransferFailure(
      commitState: state,
      failures: failures,
      recoveryPath: recoveryPath,
      resume: state == DataSyncCommitState.recoveryRequired ? null : resume,
    );
    Error.throwWithStackTrace(failure, originalStack ?? failures.first.stack);
  }

  Future<DataSyncCommitState> resume(RequestScope scope) {
    final active = _resuming;
    if (active != null) return active;
    late Future<DataSyncCommitState> result;
    result = _resume(scope).whenComplete(() {
      if (identical(_resuming, result)) _resuming = null;
    });
    return _resuming = result;
  }

  Future<DataSyncCommitState> _resume(RequestScope scope) async {
    final failures = <DataSyncDiagnostic>[];
    try {
      scope.check();
      if (importCleanup case final cleanup?) {
        try {
          await cleanup();
          importCleanup = null;
        } catch (error, stack) {
          if (error is DataSyncImportFailure) {
            importCleanup = error.resume ?? cleanup;
            recoveryPath = error.recoveryPath ?? recoveryPath;
          }
          _addDiagnostic(failures, 'import cleanup', error, stack);
        }
      }
      if (state == DataSyncCommitState.applied) {
        await finishBusiness(null, scope, failures);
      }
    } catch (error, stack) {
      _addDiagnostic(failures, 'resume finalization', error, stack);
    }
    // The original native close Future has already settled. Its diagnostic was
    // reported on the first failure; retrying does not claim to repair it.
    await closeAndDelete(null, failures);
    throwIfFailed(failures);
    return state;
  }
}

void _addDiagnostic(
  List<DataSyncDiagnostic> failures,
  String stage,
  Object error,
  StackTrace stack,
) {
  if (error is DataSyncFailure) {
    failures.addAll(error.failures);
  } else {
    failures.add((stage: stage, error: error, stack: stack));
  }
}

/// Cancel native network work, but keep the operation awaiting its cleanup.
Future<void> Function() _closeOnCancel(
  RequestScope scope,
  DataSyncRemote remote,
) {
  Future<void>? closing;
  Future<void> close() {
    if (closing != null) return closing!;
    final completion = closing = Future<void>.sync(remote.dispose);
    // Cancellation can start close long before the request returns. Observe
    // errors immediately, while retaining the original Future for final drain.
    unawaited(
      completion.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return completion;
  }

  unawaited(
    scope.whenCancelled.then((_) {
      close();
    }),
  );
  return close;
}
