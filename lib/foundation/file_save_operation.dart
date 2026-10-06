import 'dart:io';
import 'dart:typed_data';

import 'selection_operation.dart';

/// The operation owns generated sources until its complete action finishes.
/// Failed cleanup stays on that operation for release-only retries. Borrowed
/// caller files are never deleted, including when mobile export needs a copy.
Future<bool> withSaveFileSource({
  required SelectionOperation operation,
  Uint8List? data,
  File? file,
  required String filename,
  required Directory cacheDirectory,
  required Future<bool> Function(File source) save,
  bool copySource = false,
  void Function()? checkStop,
}) async {
  if (data == null && file == null) {
    throw ArgumentError('data and file cannot both be null');
  }
  operation.checkActive();
  checkStop?.call();
  Future<bool> deliver(File source) {
    operation.checkActive();
    checkStop?.call();
    return save(source);
  }

  if (data == null && !copySource) return deliver(file!);
  return operation.useTemporaryFile(
    filename: filename,
    cacheDirectory: cacheDirectory,
    prepare: (source) async {
      checkStop?.call();
      if (data != null) {
        await source.writeAsBytes(data);
      } else {
        await file!.copy(source.path);
      }
    },
    consume: deliver,
  );
}
