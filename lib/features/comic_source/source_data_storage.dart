import 'dart:io';

import 'source_mutation_failure.dart';
import 'source_data_journal.dart';

/// A failed write with a recoverable, precisely identified staging operation.
/// [state] still distinguishes persisted data from an uncommitted write.
class SourceDataWriteFailure extends SourceMutationFailure {
  SourceDataWriteFailure({
    required super.state,
    required super.failures,
    required super.recoveryPath,
    required this.cleanup,
    required this.cleanupResolvesFailure,
  });
  final SourceDataCleanup cleanup;

  /// False when filesystem cleanup cannot prove an original handle was closed.
  final bool cleanupResolvesFailure;
}

/// The file operations used by source persistence. Keeping this dependency at
/// the storage boundary also lets hosts supply their own filesystem adapter.
class SourceDataFiles {
  const SourceDataFiles();

  Future<Directory> prepare(File target, {required String operationId}) async {
    await target.parent.create(recursive: true);
    final directory = Directory(
      '${target.parent.path}/.source-data-$operationId',
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Source staging directory already exists',
        directory.path,
      );
    }
    return directory.create();
  }

  Future<void> write(File temporary, String contents) async {
    await temporary.writeAsString(contents, flush: true);
  }

  Future<void> replace(File temporary, File target) async {
    await temporary.rename(target.path);
  }

  Future<void> removeFile(File temporary) async {
    if (await temporary.exists()) await temporary.delete();
  }

  Future<void> removeDirectory(Directory directory) => directory.delete();
}

/// Write beside the destination, flush, and replace it with one rename. Never
/// truncate the previous file or delete it before a replacement is ready.
/// This does not promise directory fsync or recovery after power loss.
class SourceDataStorage {
  const SourceDataStorage({this.files = const SourceDataFiles()});

  final SourceDataFiles files;

  Future<void> write(String path, String key, String contents) async {
    final journal = SourceDataJournal.open(path)!;
    SourceDataWriteRecord? record;
    Directory? directory;
    File? temporary;
    var applied = false;
    var cleanupFailed = false;
    var journalCloseFailed = false;
    var preparing = false;
    final failures = <SourceMutationError>[];
    try {
      record = await journal.begin(key, contents);
      final target = record.target;
      SourceDataJournal.checkPath(
        journal.root,
        target.path,
        FileSystemEntityType.file,
      );
      preparing = true;
      await files.prepare(target, operationId: record.id);
      directory = record.directory;
      temporary = File('${directory.path}/contents');
      await files.write(temporary, contents);
      record.checkPaths();
      SourceDataJournal.checkPath(
        journal.root,
        target.path,
        FileSystemEntityType.file,
      );
      await files.replace(temporary, target);
      applied = true;
    } catch (error, stack) {
      failures.add((stage: 'write source data', error: error, stack: stack));
      // Directory creation can have succeeded before its Future failed. Retain
      // the intent when preparation did not transfer ownership back to us.
      if (preparing && directory == null) cleanupFailed = true;
    }
    if (temporary != null) {
      try {
        record!.checkPaths();
        await files.removeFile(temporary);
      } catch (error, stack) {
        cleanupFailed = true;
        failures.add((
          stage: 'remove source staging file',
          error: error,
          stack: stack,
        ));
      }
    }
    if (directory != null) {
      try {
        record!.checkPaths();
        // Non-recursive: do not remove files this operation does not own.
        await files.removeDirectory(directory);
      } catch (error, stack) {
        cleanupFailed = true;
        failures.add((
          stage: 'remove source staging directory',
          error: error,
          stack: stack,
        ));
      }
    }
    if (record != null) {
      try {
        if (!cleanupFailed) record.acknowledge();
      } catch (error, stack) {
        cleanupFailed = true;
        failures.add((
          stage: 'acknowledge source write cleanup',
          error: error,
          stack: stack,
        ));
      }
      try {
        await record.release();
      } catch (error, stack) {
        cleanupFailed = true;
        failures.add((
          stage: 'release source write journal',
          error: error,
          stack: stack,
        ));
      }
    }
    try {
      journal.close();
    } catch (error, stack) {
      journalCloseFailed = true;
      cleanupFailed = true;
      failures.add((
        stage: 'close source write journal',
        error: error,
        stack: stack,
      ));
    }
    if (failures.isEmpty) return;
    if (!applied && !cleanupFailed && failures.length == 1) {
      Error.throwWithStackTrace(failures.single.error, failures.single.stack);
    }
    if (cleanupFailed && record != null) {
      throw SourceDataWriteFailure(
        state: applied
            ? SourceMutationState.applied
            : SourceMutationState.recoveryRequired,
        failures: failures,
        recoveryPath: directory?.path ?? journal.directory.path,
        cleanup: record.cleanup,
        cleanupResolvesFailure:
            !journalCloseFailed &&
            !failures.any(
              (failure) => failure.error is SourceDataResourceReleaseFailure,
            ),
      );
    }
    throw SourceMutationFailure(
      state: applied
          ? SourceMutationState.applied
          : SourceMutationState.recoveryRequired,
      failures: failures,
      recoveryPath: cleanupFailed
          ? directory?.path ?? journal.directory.path
          : null,
    );
  }

  /// Called while application writers are excluded, before sources load or a
  /// whole-library import replaces their directory. Live processes retain an
  /// OS lock; recovery reports their ownership instead of deleting their work.
  Future<void> recover(String path) async {
    final journal = SourceDataJournal.open(path, create: false);
    if (journal == null) return;
    try {
      await journal.recover(_cleanRecord);
    } finally {
      journal.close();
    }
  }

  /// Runtime retries only own the recorded operation, even while another source
  /// or a later instance of the same key is writing in this directory.
  Future<void> retryCleanup(SourceDataCleanup cleanup) async {
    cleanup.verifyRoot();
    final journal = SourceDataJournal.open(cleanup.root, create: false);
    if (journal == null) {
      cleanup.verifyComplete();
      return;
    }
    try {
      await journal.recover(_cleanRecord, only: cleanup);
    } finally {
      journal.close();
    }
  }

  Future<void> _cleanRecord(SourceDataWriteRecord record) async {
    if (!await record.directory.exists()) return;
    record.checkPaths();
    await files.removeFile(record.temporary);
    record.checkPaths();
    await files.removeDirectory(record.directory);
  }
}
