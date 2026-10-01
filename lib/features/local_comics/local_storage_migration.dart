import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/file_system.dart';

/// Copies first, commits the path, then publishes it before obsolete-file cleanup.
/// The caller owns exclusion from other storage readers/writers.
class LocalStorageMigration {
  LocalStorageMigration({
    required this.copyContents,
    required this.publishPath,
    required this.reportCleanupError,
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

  Future<String?> migrate({
    required Directory source,
    required Directory destination,
    required File pathFile,
  }) async {
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
    await copyContents(source, destination);
    await _savePath(pathFile, destination.path);
    // This adapter is a synchronous assignment, not another persistence step.
    publishPath(destination.path);
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
