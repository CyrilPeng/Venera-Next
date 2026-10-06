import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_content_fingerprint.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import '../../support/dart_vm.dart';

void main() {
  const first = '11111111-1111-4111-8111-111111111111';
  const second = '22222222-2222-4222-8222-222222222222';
  final scope = DataSyncContentScope(
    endpoint: 'a' * 64,
    excludedFields: '',
    archiveSyncEnabled: false,
  );
  for (final phase in [
    'businessCommit',
    'candidate',
    'snapshot',
    'confirmed',
    'markerCleared',
    'acknowledged',
  ]) {
    test(
      'content protocol survives an independent VM killed at $phase',
      () async {
        final root = Directory.systemTemp.createTempSync('sync-content-crash-');
        addTearDown(() => root.delete(recursive: true));
        File(
          '${root.path}/appdata.json',
        ).writeAsStringSync('{"settings":{},"searchHistory":["before"]}');
        File(
          '${root.path}/implicitData.json',
        ).writeAsStringSync('{"webdavSyncPending":false}');
        final db = sqlite3.open('${root.path}/history.db');
        db.execute('CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT)');
        db.execute("INSERT INTO records VALUES (1, 'before')");
        db.dispose();
        String capture() =>
            DataSyncContentFingerprint.capture(root.path, excludedFields: '');
        final before = capture();
        var journal = DataSyncContentJournal.open(root.path);
        journal.begin(
          id: first,
          direction: 'download',
          scope: scope,
          before: before,
        );
        journal.recordSnapshot(first, before);
        journal.confirm(first);
        journal.acknowledge(first);
        journal.close();

        await _killAt(root, phase);
        journal = DataSyncContentJournal.open(root.path);
        try {
          final confirmed = [
            'confirmed',
            'markerCleared',
            'acknowledged',
          ].contains(phase);
          expect(
            journal.baseline(scope) == capture(),
            phase == 'candidate' || confirmed,
          );
          expect(
            jsonDecode(
              File('${root.path}/implicitData.json').readAsStringSync(),
            )['webdavSyncPending'],
            isFalse,
          );
          if (phase == 'businessCommit') {
            expect(capture(), isNot(before));
          } else {
            final record = journal.lookup(second);
            expect(record == null, phase == 'acknowledged');
            if (record != null) {
              expect(record.confirmed, confirmed);
              expect(record.after == null, phase == 'candidate');
            }
            if (confirmed) {
              // Later disk writes must not be absorbed by replaying an older
              // confirmation or by acknowledging its candidate after restart.
              File('${root.path}/appdata.json').writeAsStringSync(
                '{"settings":{},"searchHistory":["later-local"]}',
                flush: true,
              );
              if (record != null) {
                journal.confirm(second);
                journal.acknowledge(second);
              }
              expect(journal.baseline(scope), isNot(capture()));
            }
          }
        } finally {
          journal.close();
        }
      },
    );
  }
}

Future<void> _killAt(Directory root, String phase) async {
  final ready = File('${root.path}/ready.json');
  final child = await Process.start(dartExecutable(), [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    'test/fixtures/data_sync_content_crash_probe.dart',
    root.path,
    phase,
  ]);
  final output = child.stdout.transform(utf8.decoder).join();
  final errors = child.stderr.transform(utf8.decoder).join();
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
      fail('Content probe did not reach $phase: ${await errors}');
    }
    expect(jsonDecode(ready.readAsStringSync()), {
      'pid': child.pid,
      'phase': phase,
    });
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
