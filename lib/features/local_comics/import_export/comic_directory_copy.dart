import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/operation_failure.dart';

import 'comic_copy_record.dart';

class ComicDirectoryCopyRequest {
  ComicDirectoryCopyRequest({
    required List<String> directories,
    required this.destination,
    Map<String, String> metadata = const {},
  }) : directories = List.unmodifiable(directories),
       metadata = Map.unmodifiable(metadata);

  final List<String> directories;
  final String destination;
  final Map<String, String> metadata;
}

class ComicDirectoryCopyResult {
  ComicDirectoryCopyResult(
    Map<String, String> copies,
    Map<String, ComicDirectoryCopyFailure> failures,
  ) : copies = Map.unmodifiable(copies),
      failures = Map.unmodifiable(failures);

  final Map<String, String> copies;
  final Map<String, ComicDirectoryCopyFailure> failures;
}

class ComicDirectoryCopyFailure extends OperationFailure {
  ComicDirectoryCopyFailure({
    required this.sourcePath,
    required this.outputPath,
    required Object cause,
    required StackTrace stackTrace,
    this.cleanupError,
    this.cleanupStack,
  }) : super(
         message:
             'Failed to copy $sourcePath: $cause'
             '${cleanupError == null ? '' : '; output cleanup failed: $cleanupError'}',
         cause: cause,
         stackTrace: stackTrace,
       );

  final String sourcePath;
  final String? outputPath;
  final Object? cleanupError;
  final StackTrace? cleanupStack;
}

/// Isolate entry used by directory imports, including SAF-backed sources.
Future<ComicDirectoryCopyResult> copyComicDirectories(
  ComicDirectoryCopyRequest request,
) => overrideIO(
  () => ComicDirectoryCopier().copy(
    request.directories,
    Directory(request.destination),
    metadata: request.metadata,
  ),
);

/// Owns only newly reserved output. Existing paths are never moved or reused,
/// including empty directories and earlier results of the same import batch.
class ComicDirectoryCopier {
  ComicDirectoryCopier({
    Directory Function(Directory root, String name)? reserveDirectory,
  }) : _reserveDirectory = reserveDirectory ?? _reserve;

  final Directory Function(Directory root, String name) _reserveDirectory;

  Future<ComicDirectoryCopyResult> copy(
    List<String> sources,
    Directory root, {
    Map<String, String> metadata = const {},
  }) async {
    final copies = <String, String>{};
    final failures = <String, ComicDirectoryCopyFailure>{};
    for (final sourcePath in sources.toSet()) {
      Directory? output;
      try {
        final source = Directory(sourcePath);
        _checkDestination(source, root);
        if (ComicCopyRecord.exists(source, recursive: true)) {
          throw FileSystemException(
            'Recover the earlier copy before importing its output',
            sourcePath,
          );
        }
        output = _reserveDirectory(root, source.name);
        final record = ComicCopyRecord.prepare(
          output,
          source: sourcePath,
          metadata: metadata[sourcePath],
        );
        await copyDirectory(
          source,
          output,
          requireNonEmpty: (file) => isComicImageFileName(file.name),
        );
        await record.complete();
        copies[sourcePath] = output.path;
      } catch (error, stack) {
        Object? cleanupError;
        StackTrace? cleanupStack;
        try {
          output?.deleteIfExistsSync(recursive: true);
        } catch (error, stack) {
          cleanupError = error;
          cleanupStack = stack;
        }
        failures[sourcePath] = ComicDirectoryCopyFailure(
          sourcePath: sourcePath,
          outputPath: output?.path,
          cause: error,
          stackTrace: stack,
          cleanupError: cleanupError,
          cleanupStack: cleanupStack,
        );
      }
    }
    return ComicDirectoryCopyResult(copies, failures);
  }

  static void _checkDestination(Directory source, Directory destination) {
    final sourcePath = source is AndroidDirectory
        ? source.path
        : source.resolveSymbolicLinksSync();
    final destinationPath = destination is AndroidDirectory
        ? destination.path
        : destination.resolveSymbolicLinksSync();
    if (path.equals(sourcePath, destinationPath) ||
        path.isWithin(sourcePath, destinationPath)) {
      throw FileSystemException(
        'Import destination must not be inside its source',
        destination.path,
      );
    }
  }

  static Directory _reserve(Directory root, String sourceName) {
    // The title remains in LocalComic; the directory name is only storage
    // identity. Native createTemp reserves atomically, even across isolates.
    final prefix = '${sanitizeFileName(sourceName, maxLength: 60)}_';
    if (root is! AndroidDirectory) return root.createTempSync(prefix);
    // SAF has no exclusive directory-create or createTemp API. Use an independent
    // random identity and refuse observed collisions; provider races still need
    // real-device validation. Never guess that a same-name directory is ours.
    while (true) {
      final candidate = Directory(
        FilePath.join(root.path, '$prefix${const Uuid().v4()}'),
      );
      if (candidate.existsSync() || File(candidate.path).existsSync()) continue;
      candidate.createSync();
      if (!candidate.existsSync()) {
        throw FileSystemException(
          'Import directory was not created',
          candidate.path,
        );
      }
      return candidate;
    }
  }
}
