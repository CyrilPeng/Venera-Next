// Only the test-owned directory in args[0] is accessed. The parent kills this
// exact process at a published file boundary; no finally cleanup can run.
import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/comic_source/source_data_storage.dart';

class CrashFiles extends SourceDataFiles {
  CrashFiles(this.root, this.phase);
  final String root;
  final String phase;

  void rendezvous() {
    final marker = File('$root/ready.tmp');
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': phase}),
      flush: true,
    );
    marker.renameSync('$root/ready.json');
    stdin.readLineSync();
    throw StateError('Probe resumed instead of being terminated');
  }

  @override
  Future<Directory> prepare(File target, {required String operationId}) async {
    if (phase == 'recorded') rendezvous();
    return super.prepare(target, operationId: operationId);
  }

  @override
  Future<void> removeDirectory(Directory directory) async {
    if (phase == 'recover-cleanup') rendezvous();
    await super.removeDirectory(directory);
  }

  @override
  Future<void> write(File temporary, String contents) async {
    if (phase == 'partial') {
      await temporary.writeAsString('{"token":', flush: true);
      rendezvous();
    }
    await super.write(temporary, contents);
  }

  @override
  Future<void> replace(File temporary, File target) async {
    if (phase == 'prepared') rendezvous();
    await super.replace(temporary, target);
    if (phase == 'replaced') rendezvous();
  }
}

Future<void> main(List<String> args) async {
  final root = args[0];
  final phase = args[1];
  if (![
    'recorded',
    'partial',
    'prepared',
    'replaced',
    'recover-cleanup',
  ].contains(phase)) {
    throw ArgumentError('Unknown phase');
  }
  final storage = SourceDataStorage(files: CrashFiles(root, phase));
  if (phase == 'recover-cleanup') {
    await storage.recover(root);
  } else {
    await storage.write(root, 'test', '{"token":"new"}');
  }
}
