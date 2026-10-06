import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source_transaction_journal.dart';
import '../../support/dart_vm.dart';

Future<void> killAt(
  Directory root,
  String kind,
  String phase, {
  bool checkOwner = false,
}) async {
  final ready = File('${root.path}/ready.json');
  if (ready.existsSync()) ready.deleteSync();
  final child = await Process.start(dartExecutable(), [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    'test/fixtures/source_transaction_crash_probe.dart',
    root.path,
    kind,
    phase,
  ]);
  final errors = child.stderr.transform(utf8.decoder).join();
  final output = child.stdout.transform(utf8.decoder).join();
  var exited = false;
  final exit = child.exitCode.then((value) {
    exited = true;
    return value;
  });
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!ready.existsSync() &&
        !exited &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!ready.existsSync()) {
      if (!exited) child.kill(ProcessSignal.sigkill);
      await exit.timeout(const Duration(seconds: 10));
      fail('Source transaction probe failed at $phase: ${await errors}');
    }
    expect(jsonDecode(ready.readAsStringSync()), {
      'pid': child.pid,
      'phase': phase,
    });
    if (checkOwner) {
      await expectLater(
        SourceTransactionJournal.recover(root.path),
        throwsA(isA<FileSystemException>()),
      );
    }
    expect(child.kill(ProcessSignal.sigkill), isTrue);
    expect(await exit.timeout(const Duration(seconds: 10)), isNot(0));
    expect(await errors, isEmpty);
    expect(await output, isEmpty);
  } finally {
    if (!exited) child.kill(ProcessSignal.sigkill);
    await exit.timeout(const Duration(seconds: 10));
    await child.stdin.close();
    await errors;
    await output;
  }
}

void main() {
  final cases = {
    'replace': [
      'recorded',
      'script',
      'settingsIntent',
      'settingsPartial',
      'settings',
      'dataIntent',
      'dataApplied',
      'laterDataIntent',
      'committed',
    ],
    'install': ['recorded', 'script', 'dataIntent', 'committed'],
    'uninstall': ['settings', 'committed'],
  };
  for (final operation in cases.entries) {
    for (final phase in operation.value) {
      test(
        '${operation.key} killed at $phase recovers complete source state',
        () async {
          final root = Directory.systemTemp.createTempSync(
            'source-transaction-crash-',
          );
          addTearDown(() => root.delete(recursive: true));
          Directory('${root.path}/comic_source').createSync();
          final script = File('${root.path}/comic_source/one.js');
          if (operation.key != 'install') {
            script.writeAsStringSync('old script');
          }
          final data = File('${root.path}/comic_source/one.data')
            ..writeAsStringSync('{"token":"old"}');
          final old = jsonEncode({
            'settings': {
              'searchSources': ['old'],
              'comicSourceOrigins': {'one': 'old'},
              'theme': 'dark',
            },
            'searchHistory': ['keep'],
          });
          for (final name in ['appdata.json', 'syncdata.json']) {
            File('${root.path}/$name').writeAsStringSync(old);
          }
          await killAt(root, operation.key, phase, checkOwner: true);
          if (['script', 'settingsPartial', 'dataIntent'].contains(phase)) {
            await killAt(
              root,
              operation.key,
              operation.key == 'install'
                  ? 'recover-cleanup'
                  : 'recover-written',
            );
          }
          if (phase == 'committed') {
            await script.writeAsString('later script');
            await data.writeAsString('{"token":"later"}');
            await killAt(root, operation.key, 'recover-cleanup');
          }
          await SourceTransactionJournal.recover(root.path);
          final forward = [
            'dataIntent',
            'dataApplied',
            'laterDataIntent',
            'committed',
          ].contains(phase);
          if (phase == 'committed') {
            expect(script.readAsStringSync(), 'later script');
            expect(data.readAsStringSync(), '{"token":"later"}');
          } else {
            expect(script.existsSync(), operation.key != 'install' || forward);
            if (script.existsSync()) {
              expect(
                script.readAsStringSync(),
                forward ? 'new script' : 'old script',
              );
            }
            expect(jsonDecode(data.readAsStringSync()), {
              'token': forward
                  ? (phase == 'laterDataIntent' ? 'second' : 'first')
                  : 'old',
            });
          }
          for (final name in ['appdata.json', 'syncdata.json']) {
            final settings =
                (jsonDecode(File('${root.path}/$name').readAsStringSync())
                        as Map)['settings']
                    as Map;
            expect(
              settings['searchSources'],
              forward ? (operation.key == 'uninstall' ? [] : ['new']) : ['old'],
            );
            expect(settings['theme'], 'dark');
          }
          final db = sqlite3.open(
            '${root.path}/.source-transactions/transactions.sqlite',
          );
          try {
            expect(
              db
                  .select('SELECT COUNT(*) AS count FROM mutations')
                  .single['count'],
              0,
            );
          } finally {
            db.dispose();
          }
        },
      );
    }
  }
}
