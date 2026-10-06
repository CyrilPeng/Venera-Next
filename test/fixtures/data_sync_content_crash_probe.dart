// Standalone disk-protocol probe. This does not launch the Flutter application
// or stand in for verification of a real remote applied receipt.
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_content_fingerprint.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';

void main(List<String> args) {
  final root = args[0];
  final phase = args[1];
  const id = '22222222-2222-4222-8222-222222222222';
  final scope = DataSyncContentScope(
    endpoint: 'a' * 64,
    excludedFields: '',
    archiveSyncEnabled: false,
  );
  String capture() =>
      DataSyncContentFingerprint.capture(root, excludedFields: '');
  void stop(String at) {
    if (phase != at) return;
    final marker = File('$root/ready.tmp');
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': at}),
      flush: true,
    );
    marker.renameSync('$root/ready.json');
    stdin.readLineSync();
    throw StateError('Probe must be killed by its parent');
  }

  final journal = DataSyncContentJournal.open(root);
  try {
    final before = capture();
    if (phase == 'businessCommit') {
      final db = sqlite3.open('$root/history.db');
      // Deliberately keep the connection and WAL open until process death.
      db.execute('PRAGMA journal_mode = WAL');
      db.execute("UPDATE records SET value = 'unannounced'");
      stop('businessCommit');
    }
    journal.begin(id: id, direction: 'download', scope: scope, before: before);
    stop('candidate');
    File('$root/appdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {},
        'searchHistory': ['downloaded'],
      }),
      flush: true,
    );
    journal.recordSnapshot(id, capture());
    stop('snapshot');
    // The parent seeds a protocol baseline; receipt validation itself is covered
    // by production upload/import integration, not this process fixture.
    journal.confirm(id);
    stop('confirmed');
    File(
      '$root/implicitData.json',
    ).writeAsStringSync('{"webdavSyncPending":false}', flush: true);
    stop('markerCleared');
    journal.acknowledge(id);
    stop('acknowledged');
  } finally {
    journal.close();
  }
}
