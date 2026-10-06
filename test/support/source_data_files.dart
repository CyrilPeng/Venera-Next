import 'dart:async';
import 'dart:io';

import 'package:venera_next/features/comic_source/source_data_storage.dart';

class ControlledSourceDataFiles extends SourceDataFiles {
  FutureOr<void> Function(File file, String contents)? beforeWrite;
  FutureOr<void> Function(File temporary, File target)? beforeReplace;
  FutureOr<void> Function(Directory directory)? beforeRemoveDirectory;

  @override
  Future<void> write(File temporary, String contents) async {
    await beforeWrite?.call(temporary, contents);
    await super.write(temporary, contents);
  }

  @override
  Future<void> replace(File temporary, File target) async {
    await beforeReplace?.call(temporary, target);
    await super.replace(temporary, target);
  }

  @override
  Future<void> removeDirectory(Directory directory) async {
    await beforeRemoveDirectory?.call(directory);
    await super.removeDirectory(directory);
  }
}
