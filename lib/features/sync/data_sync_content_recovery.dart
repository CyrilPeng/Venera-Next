import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_data_import_journal.dart';
import 'data_sync_commit.dart';
import 'data_sync_content_fingerprint.dart';
import 'data_sync_content_journal.dart';
import 'data_sync_operation.dart';
import 'data_sync_upload_journal.dart';

/// The caller must own the sync directory and exclude local application data
/// replacement. This only retires proven terminal or never-started candidates.
class DataSyncContentRecovery {
  DataSyncContentRecovery({
    DataSyncContentJournal Function(String)? openContents,
    DataSyncUploadJournal Function(String)? openUploads,
    AppDataImportJournal Function(String)? openImports,
  }) : _openContents = openContents ?? DataSyncContentJournal.open,
       _openUploads = openUploads ?? DataSyncUploadJournal.open,
       _openImports = openImports ?? AppDataImportJournal.open;

  final DataSyncContentJournal Function(String) _openContents;
  final DataSyncUploadJournal Function(String) _openUploads;
  final AppDataImportJournal Function(String) _openImports;
  final _pendingClose = <void Function()>[];

  void close() {
    final failures = <DataSyncDiagnostic>[];
    for (final close in List.of(_pendingClose)) {
      try {
        close();
        _pendingClose.remove(close);
      } catch (error, stack) {
        failures.add((
          stage: 'close retained sync recovery resource',
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

  Future<bool> recover(String root, DataSyncOperation? active) async {
    close();
    final marker = File(p.join(root, 'implicitData.json'));
    final markerType = FileSystemEntity.typeSync(
      marker.path,
      followLinks: false,
    );
    if (markerType != FileSystemEntityType.file &&
        markerType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Invalid implicit sync state path',
        marker.path,
      );
    }
    DataSyncOperation? durable;
    if (marker.existsSync()) {
      final document = jsonDecode(marker.readAsStringSync());
      if (document is! Map<String, dynamic>) {
        throw const FormatException('Invalid implicit sync state');
      }
      if (document['webdavSyncOperation'] != null) {
        durable = DataSyncOperation.fromJson(document['webdavSyncOperation']);
      }
    }
    if (jsonEncode(DataSyncContentFingerprint.canonical(durable?.toJson())) !=
        jsonEncode(DataSyncContentFingerprint.canonical(active?.toJson()))) {
      throw StateError(
        'Sync recovery marker changed since settings were loaded',
      );
    }
    if (FileSystemEntity.typeSync(
          p.join(root, DataSyncContentJournal.fileName),
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      if (active != null && active.version >= 4) {
        throw StateError('Missing sync content journal');
      }
      return false;
    }
    final failures = <DataSyncDiagnostic>[];
    final closers = <void Function()>[];
    var unstartedDownload = false;
    try {
      final contents = _openContents(root);
      closers.add(contents.close);
      final uploads = _openUploads(root);
      closers.add(uploads.close);
      final imports = _openImports(root);
      closers.add(imports.close);
      final records = contents.records;
      if (active != null &&
          active.version >= 4 &&
          !records.any((record) => record.id == active.id)) {
        throw StateError('Missing active synchronized content evidence');
      }
      for (final record in records) {
        try {
          final upload = uploads.lookup(record.id);
          final hasImport = imports.containsSyncOperation(record.id);
          final receipts = imports.receipts
              .where((receipt) => receipt.syncOperationId == record.id)
              .toList();
          if (receipts.length > 1 ||
              (record.direction == 'upload' && hasImport) ||
              (record.direction == 'download' && upload != null)) {
            throw StateError('Conflicting sync content transfer evidence');
          }
          final receipt = receipts.singleOrNull;
          if (upload != null &&
              upload.endpointFingerprint != record.scope.endpoint) {
            throw StateError('Upload endpoint disagrees with content');
          }
          final hasUploadDirectory =
              FileSystemEntity.typeSync(
                uploads.operationDirectory(record.id).path,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound;
          if (upload == null && hasUploadDirectory) {
            throw StateError('Upload directory has no matching receipt');
          }
          final neverStarted =
              record.after == null &&
              upload == null &&
              !hasImport &&
              !hasUploadDirectory;
          if (record.id == active?.id) {
            if (record.direction != active!.direction.name ||
                record.scope.endpoint !=
                    dataSyncEndpointFingerprint(active.connection) ||
                record.scope.excludedFields !=
                    DataSyncContentScope(
                      endpoint: record.scope.endpoint,
                      excludedFields: active.excludedFields,
                      archiveSyncEnabled: record.scope.archiveSyncEnabled,
                    ).excludedFields) {
              throw StateError(
                'Sync candidate direction disagrees with marker',
              );
            }
            unstartedDownload =
                record.direction == 'download' &&
                !hasImport &&
                (neverStarted ||
                    record.completedState == DataSyncCommitState.notApplied);
            continue;
          }
          if (record.completedState == null) {
            final rolledBack = record.direction == 'upload'
                ? upload?.isTerminal == true &&
                      upload?.commitState == DataSyncCommitState.notApplied
                : receipt?.commitState == DataSyncCommitState.notApplied;
            if (!neverStarted && !rolledBack) {
              throw StateError(
                'Unfinished sync content has no matching active marker',
              );
            }
            contents.completeNotApplied(record.id);
          }
          final completed = contents.lookup(record.id)!;
          contents.verifyCompleted(completed);
          if (upload != null) {
            if (!upload.isTerminal ||
                upload.commitState != completed.completedState ||
                upload.endpointFingerprint != record.scope.endpoint ||
                (completed.confirmed && upload.sha256 != record.archiveHash)) {
              throw StateError('Upload cleanup receipt disagrees with content');
            }
            await uploads.acknowledge(record.id);
          }
          if (hasImport) {
            if (receipt == null ||
                receipt.commitState != completed.completedState) {
              throw StateError('Import cleanup receipt disagrees with content');
            }
            await imports.acknowledge(receipt.id);
          }
          contents.acknowledge(record.id);
        } catch (error, stack) {
          failures.add((
            stage: 'recover sync content ${record.id}',
            error: error,
            stack: stack,
          ));
        }
      }
    } catch (error, stack) {
      failures.add((
        stage: 'read sync content recovery',
        error: error,
        stack: stack,
      ));
    } finally {
      for (final close in closers.reversed) {
        try {
          close();
        } catch (error, stack) {
          _pendingClose.add(close);
          failures.add((
            stage: 'close sync content recovery',
            error: error,
            stack: stack,
          ));
        }
      }
    }
    if (failures.isNotEmpty) {
      throw DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        failures: failures,
      );
    }
    return unstartedDownload;
  }
}
