// Independent disk protocol with real journals. No Flutter runtime or remote.
import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_recovery.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';

Future<void> main(List<String> args) async {
  final root = args[0];
  final phase = args[1];
  final owner = SqliteDataSyncOwnership(() => root)..acquire();
  void stop() {
    File(
      '$root/recovery-ready.tmp',
    ).writeAsStringSync(jsonEncode({'pid': pid, 'phase': phase}), flush: true);
    File('$root/recovery-ready.tmp').renameSync('$root/recovery-ready');
    stdin.readLineSync();
    throw StateError('Parent must kill this process');
  }

  try {
    if (phase.startsWith('recover-')) {
      final recovery = DataSyncContentRecovery(
        openImports: (path) => AppDataImportJournal.open(
          path,
          observer: (event) {
            if (event.phase == phase.substring('recover-'.length)) stop();
          },
        ),
      );
      try {
        await recovery.recover(root, null);
      } finally {
        recovery.close();
      }
      throw StateError('Recovery checkpoint not reached');
    }
    final journal = DataSyncContentJournal.open(root);
    final imports = AppDataImportJournal.open(root);
    try {
      const id = '11111111-1111-4111-8111-111111111111';
      final scope = DataSyncContentScope(
        endpoint: 'a' * 64,
        excludedFields: '',
        archiveSyncEnabled: false,
      );
      journal.begin(
        id: id,
        direction: 'download',
        scope: scope,
        before: 'b' * 64,
      );
      if (phase == 'candidate') stop();
      final transaction = await imports.prepare(
        resources: {},
        syncOperationId: id,
      );
      final applied = phase.startsWith('applied');
      if (applied) {
        journal.recordSnapshot(id, 'c' * 64);
        await transaction.markApplied(DateTime.now().millisecondsSinceEpoch);
        journal.confirm(id);
      } else {
        await transaction.markRolledBack();
        journal.completeNotApplied(id);
      }
      if (phase.endsWith('receiptAck')) {
        await imports.acknowledge(transaction.id);
      }
      stop();
    } finally {
      imports.close();
      journal.close();
    }
  } finally {
    owner.release();
  }
}
