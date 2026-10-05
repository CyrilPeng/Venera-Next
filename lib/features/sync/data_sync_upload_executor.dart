import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:venera_next/network/request_scope.dart';

import 'data_sync_archive_order.dart';
import 'data_sync_commit.dart';
import 'data_sync_remote_port.dart';
import 'data_sync_upload_journal.dart';

typedef DataSyncUploadObserver =
    FutureOr<void> Function(DataSyncUploadEvent event);

class DataSyncUploadEvent {
  const DataSyncUploadEvent(this.phase, this.id, [this.remoteName]);
  final String phase;
  final String id;
  final String? remoteName;
}

/// Upload/recovery share one durable operation identity. Only the initial
/// preparation can export; all later attempts use the immutable owned snapshot.
class DataSyncUploadExecutor {
  DataSyncUploadExecutor({
    required this.journal,
    required this.endpointFingerprint,
    required this.openRemote,
    required this.prepareVersion,
    required this.exportData,
    required this.recordSyncTime,
    DateTime Function()? now,
    this.observer,
  }) : now = now ?? DateTime.now;

  final DataSyncUploadJournal journal;
  final String endpointFingerprint;
  final DataSyncRemote Function() openRemote;
  final Future<int> Function() prepareVersion;
  final Future<void> Function(File destination) exportData;
  final Future<void> Function(int) recordSyncTime;
  final DateTime Function() now;
  final DataSyncUploadObserver? observer;

  Future<DataSyncCommitState> upload(String operationId, RequestScope scope) =>
      _execute(operationId, scope, recovering: false);
  Future<DataSyncCommitState> recover(String operationId, RequestScope scope) =>
      _execute(operationId, scope, recovering: true);

  Future<void> _event(
    String phase,
    DataSyncUploadRecord record, [
    String? remoteName,
  ]) async => observer?.call(
    DataSyncUploadEvent(
      phase,
      record.operationId,
      remoteName ?? record.remoteName,
    ),
  );

  Future<DataSyncCommitState> _execute(
    String id,
    RequestScope scope, {
    required bool recovering,
  }) async {
    DataSyncUploadRecord? record;
    DataSyncRemote? remote;
    Future<void>? closeFuture;
    var watchingCancellation = true;
    var remoteClosed = false;
    var accepted = false;
    var stage = 'upload journal';
    final failures = <DataSyncDiagnostic>[];
    Future<void> closeRemote() =>
        closeFuture ??= Future<void>.sync(remote!.dispose);
    try {
      scope.check();
      final existing = journal.lookup(id);
      if (existing != null &&
          existing.endpointFingerprint != endpointFingerprint) {
        throw StateError('Upload endpoint does not match its recovery journal');
      }
      record = existing;
      accepted = true;
      if (record?.isTerminal == true) return record!.commitState;
      final isNew = record == null;
      if (isNew) {
        record = DataSyncUploadRecord(
          operationId: id,
          endpointFingerprint: endpointFingerprint,
        );
        journal.save(record);
        await _event('preparing', record);
      }
      if (record.phase == 'preparing') {
        if (recovering || !isNew) {
          await _notApplied(record);
          return DataSyncCommitState.notApplied;
        }
        stage = 'prepare upload snapshot';
        await _prepare(record, scope);
      }
      stage = 'open upload remote';
      scope.check();
      remote = openRemote();
      unawaited(
        scope.whenCancelled.then((_) {
          if (watchingCancellation) {
            // The finalizer joins this same future and retains a close failure.
            unawaited(closeRemote().catchError((Object _, StackTrace _) {}));
          }
        }),
      );
      if (record.commitState != DataSyncCommitState.applied) {
        stage = 'reconcile upload snapshot';
        await _commit(record, remote, scope);
      }
      if (record.commitState == DataSyncCommitState.applied) {
        record.phase = 'finalizing';
        journal.save(record);
        for (final candidate in List.of(record.retention)) {
          try {
            scope.check();
            await _retain(record, candidate, remote, scope);
          } catch (error, stack) {
            _diagnostic(failures, 'retention ${candidate.name}', error, stack);
          }
        }
        if (!record.timeSaved) {
          try {
            scope.check();
            await recordSyncTime(record.committedAt!);
            record.timeSaved = true;
            journal.save(record);
            await _event('timeSaved', record);
          } catch (error, stack) {
            _diagnostic(failures, 'record upload sync time', error, stack);
          }
        }
      }
    } catch (error, stack) {
      _diagnostic(failures, stage, error, stack);
    } finally {
      watchingCancellation = false;
      if (remote != null) {
        try {
          await closeRemote();
          remoteClosed = true;
          if (record != null) await _event('remoteClosed', record);
        } catch (error, stack) {
          _diagnostic(failures, 'close upload remote', error, stack);
        }
      }
    }

    if (record != null) {
      try {
        // Always use persisted state after a failed write. A mutated in-memory
        // phase cannot authorize removal of the only recoverable snapshot.
        record = journal.lookup(id)!;
        if (record.phase == 'preparing') {
          await _notApplied(record);
        } else if (record.commitState == DataSyncCommitState.applied &&
            remoteClosed &&
            !record.sourceCleaned) {
          await journal.cleanup(id);
          record.sourceCleaned = true;
          journal.save(record);
          await _event('sourceCleaned', record);
        }
        if (record.commitState == DataSyncCommitState.applied &&
            record.retention.isEmpty &&
            record.timeSaved &&
            record.sourceCleaned &&
            remoteClosed) {
          record.phase = 'finished';
          journal.save(record);
          await _event('terminal', record);
        }
      } catch (error, stack) {
        _diagnostic(failures, 'finalize upload journal', error, stack);
      }
    }
    DataSyncCommitState state;
    try {
      state = accepted
          ? journal.lookup(id)?.commitState ??
                DataSyncCommitState.recoveryRequired
          : DataSyncCommitState.recoveryRequired;
    } catch (error, stack) {
      state = DataSyncCommitState.recoveryRequired;
      _diagnostic(failures, 'read upload outcome', error, stack);
    }
    if (failures.isNotEmpty) {
      throw DataSyncFailure(
        commitState: state,
        failures: failures,
        recoveryPath: journal.dataPath,
      );
    }
    return state;
  }

  Future<void> _notApplied(DataSyncUploadRecord record) async {
    await journal.cleanup(record.operationId);
    record.sourceCleaned = true;
    record.phase = 'notApplied';
    journal.save(record);
    await _event('sourceCleaned', record);
    await _event('terminal', record);
  }

  Future<void> _prepare(DataSyncUploadRecord record, RequestScope scope) async {
    scope.check();
    final version = await prepareVersion();
    scope.check();
    if (version < 0) throw StateError('Invalid upload version');
    final day = now().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    if (day < 0) throw StateError('Invalid upload date');
    final snapshot = journal.snapshotFile(record.operationId);
    final directory = journal.operationDirectory(record.operationId);
    scope.check();
    if (directory.existsSync()) {
      throw StateError('Upload snapshot directory already exists');
    }
    record.sourceOwned = true;
    journal.save(record);
    await directory.create();
    journal.snapshotFile(
      record.operationId,
    ); // Recheck after creating directory.
    await exportData(snapshot);
    journal.snapshotFile(
      record.operationId,
    ); // Reject an exporter-created link.
    if (!snapshot.existsSync()) {
      throw StateError('Exporter did not write a snapshot');
    }
    // Flush OS file buffers before the durable prepared record permits any PUT.
    final handle = await snapshot.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _event('snapshotWritten', record);
    scope.check();
    final length = await snapshot.length();
    final hash = (await crypto.sha256.bind(snapshot.openRead()).single)
        .toString();
    record.version = version;
    record.remoteName = '$day-$version-${record.operationId}.venera';
    record.length = length;
    record.sha256 = hash;
    record.phase = 'prepared';
    journal.save(record);
    await _event('prepared', record);
  }

  Future<void> _commit(
    DataSyncUploadRecord record,
    DataSyncRemote remote,
    RequestScope scope,
  ) async {
    scope.check();
    final probe = await remote.probeArchive(record.remoteName!);
    if (probe is DataSyncArchivePresent) {
      _requireMatch(record, probe);
      await _confirmed(record);
      return;
    }
    scope.check();
    final snapshot = journal.snapshotFile(record.operationId);
    if (!snapshot.existsSync() ||
        await snapshot.length() != record.length ||
        (await crypto.sha256.bind(snapshot.openRead()).single).toString() !=
            record.sha256) {
      throw StateError(
        'Upload snapshot is missing or corrupt; preserve recovery evidence',
      );
    }
    if (!record.retentionPlanned) {
      await _planRetention(record, remote, scope);
    }
    scope.check();
    record.phase = 'putPending';
    journal.save(record);
    await _event('putPending', record);
    scope.check();
    final result = await remote.createArchiveIfAbsent(
      record.remoteName!,
      snapshot,
      sha256: record.sha256!,
      length: record.length!,
    );
    await _event('afterPut', record);
    if (result == DataSyncArchiveCreateResult.preconditionFailed) {
      final existing = await remote.probeArchive(record.remoteName!);
      if (existing is! DataSyncArchivePresent) {
        throw StateError(
          'Conditional upload failed without matching remote evidence',
        );
      }
      _requireMatch(record, existing);
    }
    // Do not check cancellation between a successful response and its durable
    // receipt: cancellation cannot reverse the established remote commit.
    await _confirmed(record);
  }

  void _requireMatch(
    DataSyncUploadRecord record,
    DataSyncArchivePresent probe,
  ) {
    if (probe.sha256 != record.sha256 || probe.length != record.length) {
      throw StateError('Remote upload name contains different content');
    }
  }

  Future<void> _confirmed(DataSyncUploadRecord record) async {
    final time = record.committedAt ?? now().millisecondsSinceEpoch;
    if (!isValidDataSyncCommitTime(time)) {
      throw StateError('Invalid upload commit time');
    }
    // A matching object can exist before this operation's initial PUT; no
    // retention plan then exists, so there is no authorized archive to remove.
    record.retentionPlanned = true;
    record.committedAt = time;
    record.phase = 'confirmed';
    journal.save(record);
    await _event('confirmed', record);
  }

  Future<void> _planRetention(
    DataSyncUploadRecord record,
    DataSyncRemote remote,
    RequestScope scope,
  ) async {
    scope.check();
    final names =
        (await remote.listNames())
            .where((name) => name.endsWith('.venera'))
            .toList()
          ..sort(compareDataSyncArchiveNames);
    final day = record.remoteName!.split('-').first;
    final selected = <String>{};
    final today = names
        .where((name) => name.split('-').first == day)
        .firstOrNull;
    if (today != null) selected.add(today);
    if (names.length >= 10) selected.add(names.first);
    selected.remove(record.remoteName);
    final plan = <DataSyncRetentionIdentity>[];
    for (final name in selected) {
      scope.check();
      final probe = await remote.probeArchive(name);
      if (probe is DataSyncArchivePresent) {
        plan.add(
          DataSyncRetentionIdentity(
            name: name,
            sha256: probe.sha256,
            length: probe.length,
            strongEtag: probe.strongEtag,
          ),
        );
      }
    }
    record.retention
      ..clear()
      ..addAll(plan);
    record.retentionPlanned = true;
    journal.save(record);
    await _event('retentionPlanned', record);
  }

  Future<void> _retain(
    DataSyncUploadRecord record,
    DataSyncRetentionIdentity candidate,
    DataSyncRemote remote,
    RequestScope scope,
  ) async {
    var probe = await remote.probeArchive(candidate.name);
    bool same(DataSyncArchiveProbe value) =>
        value is DataSyncArchivePresent &&
        value.sha256 == candidate.sha256 &&
        value.length == candidate.length;
    if (same(probe)) {
      final tag = (probe as DataSyncArchivePresent).strongEtag;
      if (tag == null) {
        throw StateError(
          'Retention requires a strong ETag for ${candidate.name}',
        );
      }
      scope.check();
      await _event('beforeRetentionRemove', record, candidate.name);
      final result = await remote.removeArchiveIfUnchanged(
        candidate.name,
        strongEtag: tag,
      );
      if (result == DataSyncArchiveRemoveResult.preconditionFailed) {
        probe = await remote.probeArchive(candidate.name);
        if (same(probe)) {
          throw StateError(
            'Retention archive changed its ETag; retry cleanup with fresh evidence',
          );
        }
      }
    }
    // Missing or changed content proves that the original candidate is gone.
    // Never delete the replacement, even when it has the same filename.
    record.retention.removeWhere((entry) => entry.name == candidate.name);
    journal.save(record);
    await _event('retentionCompleted', record, candidate.name);
  }
}

void _diagnostic(
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
