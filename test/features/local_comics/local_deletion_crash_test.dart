import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_deletion_journal.dart';

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

void main() {
  for (final phase in ['staged', 'transaction', 'committed']) {
    test(
      'forced process termination recovers $phase deletion',
      () async {
        final root = Directory.systemTemp.createTempSync(
          'local-deletion-crash-',
        );
        Process? child;
        Future<String>? errors;
        Future<String>? output;
        var exited = false;
        try {
          child = await Process.start(dartExecutable(), [
            '--packages=${p.absolute('.dart_tool/package_config.json')}',
            'test/fixtures/local_deletion_crash_probe.dart',
            root.path,
            phase,
          ]);
          errors = child.stderr.transform(utf8.decoder).join();
          output = child.stdout.transform(utf8.decoder).join();
          final exitCode = child.exitCode.then((value) {
            exited = true;
            return value;
          });
          final ready = File('${root.path}/ready.json');
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!ready.existsSync() &&
              !exited &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          if (!ready.existsSync()) {
            if (!exited) child.kill(ProcessSignal.sigkill);
            await exitCode.timeout(const Duration(seconds: 10));
            fail('Probe did not reach $phase: ${await errors}');
          }
          final state =
              jsonDecode(ready.readAsStringSync()) as Map<String, dynamic>;
          expect(state, {'pid': child.pid, 'phase': phase});
          expect(Directory('${root.path}/book').existsSync(), isFalse);
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          expect(await exitCode.timeout(const Duration(seconds: 10)), isNot(0));
          expect(await errors, isEmpty);
          expect(await output, isEmpty);

          final db = sqlite3.open('${root.path}/local.db');
          try {
            final expectedCount = phase == 'committed' ? 0 : 1;
            expect(
              db.select('SELECT * FROM records'),
              hasLength(expectedCount),
            );
            final pending = db
                .select('SELECT * FROM local_deletion_journal')
                .single;
            expect(pending['committed'], phase == 'committed' ? 1 : 0);
            for (final name in ['favorites', 'history']) {
              final other = sqlite3.open('${root.path}/$name.db');
              try {
                expect(
                  other.select('SELECT * FROM records'),
                  hasLength(expectedCount),
                );
              } finally {
                other.dispose();
              }
            }
            if (phase == 'committed') {
              Directory('${root.path}/book').createSync();
              File('${root.path}/book/new').writeAsStringSync('new owner');
            }
            final journal = LocalDeletionJournal(
              db,
              exists: (path) async =>
                  await FileSystemEntity.type(path, followLinks: false) !=
                  FileSystemEntityType.notFound,
            )..initialize();
            await journal.recover();
            expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
            expect(
              Directory(pending['quarantine_path'] as String).existsSync(),
              isFalse,
            );
            if (phase == 'committed') {
              expect(
                File('${root.path}/book/new').readAsStringSync(),
                'new owner',
              );
              expect(File('${root.path}/book/page').existsSync(), isFalse);
            } else {
              expect(
                File('${root.path}/book/page').readAsStringSync(),
                'original bytes',
              );
            }
            await journal.recover();
          } finally {
            db.dispose();
          }
        } finally {
          if (child != null) {
            if (!exited) child.kill(ProcessSignal.sigkill);
            await child.exitCode.timeout(const Duration(seconds: 10));
            await child.stdin.close();
            await errors;
            await output;
          }
          root.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
