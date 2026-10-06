import 'dart:io';
import 'package:path/path.dart' as p;

String dartExecutable() {
  final executable = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    for (final relative in [
      'bin/cache/dart-sdk/bin/$executable',
      'bin/$executable',
    ]) {
      final candidate = File(p.join(directory.path, relative));
      if (candidate.existsSync()) {
        final vm = File(
          p.join(
            candidate.parent.path,
            Platform.isWindows ? 'dartvm.exe' : 'dartvm',
          ),
        );
        return vm.existsSync() ? vm.path : candidate.path;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Cannot locate the Dart SDK executable without a shell');
}
