import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/file_system.dart';
import 'local_comic_model.dart';
import 'local_storage_relocation.dart';
import 'local_deletion_paths.dart';

/// Evidence retained by the owning manager while its connection is uncertain.
/// Only preparation can fail without a durable journal: after commit starts,
/// missing recovery evidence must never be interpreted as a rollback.
class LocalStorageRelocationAttempt {
  LocalStorageRelocationAttempt._(this.source, this.destination);
  final String source;
  final String destination;
  bool _commitStarted = false;
}

/// Copies first, commits the path, then publishes it before obsolete-file cleanup.
/// The caller owns exclusion from other storage readers/writers.
class LocalStorageMigration {
  LocalStorageMigration({
    required this.copyContents,
    required this.publishPath,
    required this.reportCleanupError,
    this.relocation,
    this.checkCopyOwnership,
    this.invalidateAuthority,
    this.publishRelocation,
    this.resolveReference = resolveLocalNativePath,
    Future<void> Function(Directory)? clearContents,
    Future<String> Function(Directory)? canonicalPath,
  }) : _clearContents =
           clearContents ?? ((directory) => directory.deleteContents()),
       _canonicalPath =
           canonicalPath ?? ((directory) => directory.resolveSymbolicLinks());

  final Future<void> Function(Directory, Directory) copyContents;
  final void Function(String) publishPath;
  final void Function(Object, StackTrace) reportCleanupError;
  final Future<void> Function(Directory) _clearContents;
  final Future<String> Function(Directory) _canonicalPath;
  final LocalStorageRelocation? relocation;
  final Future<void> Function(LocalComic)? checkCopyOwnership;
  final Future<String> Function(String) resolveReference;
  final void Function(LocalStorageRelocationAttempt)? invalidateAuthority;
  final void Function(LocalStorageRelocationState)? publishRelocation;

  /// Pending committed state is authoritative even if mirroring local_path or
  /// retiring copied receipts fails again. Startup can still open that library.
  Future<String?> recover(
    File pathFile, {
    LocalStorageRelocationAttempt? attempt,
  }) async {
    if (attempt != null && !relocation!.db.autocommit) {
      // This attempt started its own transaction after exclusive admission.
      // A failed rollback must be resolved before reading durable state.
      relocation!.db.execute('ROLLBACK;');
    }
    _requireSettledTransaction();
    final state = relocation?.pending;
    if (state == null) {
      if (attempt == null) return null;
      return _publishBeforeCommit(attempt);
    }
    if (attempt != null &&
        (state.source != attempt.source ||
            state.destination != attempt.destination)) {
      throw StateError('Library relocation recovery evidence changed');
    }
    final recoveryAttempt =
        attempt ??
        (LocalStorageRelocationAttempt._(state.source, state.destination)
          .._commitStarted = true);
    invalidateAuthority?.call(recoveryAttempt);
    if (!state.committed) {
      if (!Directory(state.source).existsSync()) {
        throw FileSystemException(
          'Uncommitted library source is missing',
          state.source,
        );
      }
      if (pathFile.existsSync() &&
          !p.equals(pathFile.readAsStringSync(), state.source)) {
        throw StateError(
          'Uncommitted relocation has an unexpected library path',
        );
      }
      _publish(state);
      relocation!.forget();
      return state.source;
    }
    if (!Directory(state.destination).existsSync()) {
      throw FileSystemException(
        'Committed library destination is missing',
        state.destination,
      );
    }
    _publish(state);
    try {
      await _finishCommitted(pathFile, state.destination);
    } catch (error, stack) {
      reportCleanupError(error, stack);
    }
    return state.destination;
  }

  void _requireSettledTransaction() {
    if (relocation?.db.autocommit == false) {
      throw StateError('Library relocation transaction is still unresolved');
    }
  }

  String _publishBeforeCommit(LocalStorageRelocationAttempt attempt) {
    if (attempt._commitStarted) {
      throw StateError('Library relocation recovery evidence is missing');
    }
    if (!Directory(attempt.source).existsSync()) {
      throw FileSystemException(
        'Uncommitted library source is missing',
        attempt.source,
      );
    }
    publishPath(attempt.source);
    return attempt.source;
  }

  void _publish(LocalStorageRelocationState state) {
    final root = state.committed ? state.destination : state.source;
    if (!Directory(root).existsSync()) {
      throw FileSystemException(
        'Authoritative library directory is missing',
        root,
      );
    }
    if (publishRelocation != null) {
      publishRelocation!(state);
    } else {
      publishPath(root);
    }
  }

  Future<void> _finishCommitted(File pathFile, String destination) async {
    if (!Directory(destination).existsSync()) {
      throw FileSystemException(
        'Committed library destination is missing',
        destination,
      );
    }
    await _savePath(pathFile, destination);
    if (checkCopyOwnership == null &&
        relocation!.pending!.cleanups.isNotEmpty) {
      throw StateError('Copy receipt ownership validation is required');
    }
    if (checkCopyOwnership != null) {
      await relocation!.retireCopyReceipts(checkCopyOwnership!);
    }
    relocation!.forget();
  }

  Future<String?> migrate({
    required Directory source,
    required Directory destination,
    required File pathFile,
  }) async {
    if (relocation?.pending != null) {
      await recover(pathFile);
      if (relocation?.pending != null) {
        throw StateError(
          'Finish the pending library relocation before moving again',
        );
      }
      // The supplied source may have been captured before recovery selected a
      // committed root. A new call must capture the now-authoritative library.
      return 'Local library recovery completed. Try moving the library again.';
    }
    if (!await destination.exists()) return 'Directory does not exist';
    final sourcePath = p.normalize(p.absolute(await _canonicalPath(source)));
    final destinationPath = p.normalize(
      p.absolute(await _canonicalPath(destination)),
    );
    if (p.equals(sourcePath, destinationPath) ||
        p.isWithin(sourcePath, destinationPath) ||
        p.isWithin(destinationPath, sourcePath)) {
      return 'Source and destination directories must not overlap';
    }
    if (!await destination.list().isEmpty) return 'Directory is not empty';
    final snapshot = relocation?.snapshot();
    final targets = await relocation?.destinations(
      source.path,
      destination.path,
      resolvePath: resolveReference,
    );
    await copyContents(source, destination);
    if (relocation == null) {
      await _savePath(pathFile, destination.path);
      publishPath(destination.path);
    } else {
      final attempt = LocalStorageRelocationAttempt._(
        source.path,
        destination.path,
      );
      invalidateAuthority?.call(attempt);
      try {
        relocation!.prepare(source.path, destination.path, snapshot!, targets!);
        attempt._commitStarted = true;
        _publish(relocation!.commit(snapshot));
      } catch (error, stack) {
        // COMMIT may have succeeded before acknowledgement failed. The durable
        // journal decides the active root; never clear either copy on failure.
        try {
          _requireSettledTransaction();
          final state = relocation!.pending;
          if (state == null) {
            _publishBeforeCommit(attempt);
          } else {
            _publish(state);
          }
        } catch (recoveryError, recoveryStack) {
          reportCleanupError(recoveryError, recoveryStack);
        }
        Error.throwWithStackTrace(error, stack);
      }
      await _finishCommitted(pathFile, destination.path);
    }
    try {
      await _clearContents(source);
    } catch (error, stack) {
      // A valid committed destination remains authoritative if cleanup fails.
      reportCleanupError(error, stack);
    }
    return null;
  }

  Future<void> _savePath(File target, String path) async {
    final staging = await target.parent.createTemp('.local-path-');
    try {
      final file = File(FilePath.join(staging.path, 'path'));
      await file.writeAsString(path, flush: true);
      await file.rename(target.path);
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (error, stack) {
        reportCleanupError(error, stack);
      }
    }
  }
}
