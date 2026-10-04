import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Both failures remain observable when saving and retiring its source fail.
class FileSaveCleanupFailure implements Exception {
  const FileSaveCleanupFailure({
    required this.operationError,
    required this.operationStackTrace,
    required this.cleanupError,
    required this.cleanupStackTrace,
  });

  final Object operationError;
  final StackTrace operationStackTrace;
  final Object cleanupError;
  final StackTrace cleanupStackTrace;

  @override
  String toString() =>
      'File save failed: $operationError; temporary source cleanup failed: '
      '$cleanupError';
}

/// A dialog may borrow [File] until its returned Future completes. Only this
/// operation's unique staging directory is deleted; caller files remain owned
/// by the caller, even when [copySource] requests a staged copy.
Future<bool> withSaveFileSource({
  Uint8List? data,
  File? file,
  required String filename,
  required Directory cacheDirectory,
  required Future<bool> Function(File source) save,
  bool copySource = false,
  void Function()? checkStop,
}) async {
  if (data == null && file == null) {
    throw Exception('data and file cannot be null at the same time');
  }
  Directory? temporary;
  Object? operationError;
  StackTrace? operationStack;
  try {
    checkStop?.call();
    var source = file;
    if (data != null || copySource) {
      // Uniqueness belongs to the directory, preserving the suggested basename
      // and extension. A filename never determines a path outside this owner.
      final name = p.posix.basename(filename.replaceAll('\\', '/'));
      if (name.isEmpty || name == '.' || name == '..') {
        throw ArgumentError.value(filename, 'filename', 'Missing file name');
      }
      temporary = await cacheDirectory.createTemp('save-file-');
      checkStop?.call();
      source = File(p.join(temporary.path, name));
      if (data != null) {
        await source.writeAsBytes(data);
      } else {
        await file!.copy(source.path);
      }
    }
    checkStop?.call();
    return await save(source!);
  } catch (error, stack) {
    operationError = error;
    operationStack = stack;
    rethrow;
  } finally {
    if (temporary != null) {
      try {
        await temporary.delete(recursive: true);
      } catch (cleanupError, cleanupStack) {
        if (operationError != null) {
          Error.throwWithStackTrace(
            FileSaveCleanupFailure(
              operationError: operationError,
              operationStackTrace: operationStack!,
              cleanupError: cleanupError,
              cleanupStackTrace: cleanupStack,
            ),
            operationStack,
          );
        }
        Error.throwWithStackTrace(cleanupError, cleanupStack);
      }
    }
  }
}
