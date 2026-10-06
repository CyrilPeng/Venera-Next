import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_recovery.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import '../../support/dart_vm.dart';

void main() {
  for (final phase in [
    'candidate',
    'applied-markerCleared',
    'notApplied-markerCleared',
    'applied-receiptAck',
    'notApplied-receiptAck',
  ]) {
    test('orphan recovery after independent VM termination at $phase', () async {
      final root = Directory.systemTemp.createTempSync('sync-recovery-kill-');
      try {
        await _kill(root, phase);
        if (phase.endsWith('markerCleared')) {
          // Interrupt actual recovery twice: while deleting the before-image,
          // then after all files are removed but before receipt acknowledgement.
          await _kill(root, 'recover-cleanupResource');
          await _kill(root, 'recover-cleaned');
        }
        final owner = SqliteDataSyncOwnership(() => root.path)..acquire();
        final recovery = DataSyncContentRecovery();
        try {
          expect(await recovery.recover(root.path, null), isFalse);
          final contents = DataSyncContentJournal.open(root.path);
          final imports = AppDataImportJournal.open(root.path);
          try {
            expect(contents.records, isEmpty);
            expect(imports.receipts, isEmpty);
            expect(
              contents.baseline(
                DataSyncContentScope(
                  endpoint: 'a' * 64,
                  excludedFields: '',
                  archiveSyncEnabled: false,
                ),
              ),
              phase.startsWith('applied') ? 'c' * 64 : isNull,
            );
          } finally {
            imports.close();
            contents.close();
          }
        } finally {
          recovery.close();
          owner.release();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    });
  }
}

Future<void> _kill(Directory root, String phase) async {
  final ready = File('${root.path}/recovery-ready');
  if (ready.existsSync()) ready.deleteSync();
  final child = await Process.start(dartExecutable(), [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    'test/fixtures/data_sync_content_recovery_probe.dart',
    root.path,
    phase,
  ]);
  final output = child.stdout.transform(utf8.decoder).join();
  final errors = child.stderr.transform(utf8.decoder).join();
  var exited = false;
  final exit = child.exitCode.then((code) {
    exited = true;
    return code;
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
      fail('Recovery checkpoint $phase not reached: ${await errors}');
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
