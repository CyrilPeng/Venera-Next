// A separate OS process intentionally killed by the recovery integration test.
// Uses only the test-owned directory passed by that test.
import 'dart:convert';
import 'dart:io';

import 'package:venera_next/features/local_comics/local_deletion_journal.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

Future<void> main(List<String> args) async {
  final root = args[0];
  final phase = args[1];
  if (!['staged', 'transaction', 'committed'].contains(phase)) {
    throw ArgumentError('Unknown crash probe phase');
  }
  final db = openSqliteDatabase('$root/local.db');
  final journal = LocalDeletionJournal(
    db,
    exists: (path) async =>
        await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound,
  )..initialize();
  for (final name in ['favorites', 'history']) {
    db.execute('ATTACH DATABASE ? AS $name', ['$root/$name.db']);
  }
  for (final name in ['main', 'favorites', 'history']) {
    db.execute(
      'CREATE TABLE $name.records(id INTEGER PRIMARY KEY); INSERT INTO $name.records VALUES(1);',
    );
  }
  final directory = Directory('$root/book')..createSync();
  File(
    '${directory.path}/page',
  ).writeAsStringSync('original bytes', flush: true);
  void rendezvous() {
    final marker = File('$root/ready.tmp');
    marker.writeAsStringSync(
      jsonEncode({'pid': pid, 'phase': phase}),
      flush: true,
    );
    marker.renameSync('$root/ready.json');
    // No event-loop or finally cleanup after the marker: the parent terminates
    // this exact process while its SQLite/file state remains at the checkpoint.
    stdin.readLineSync();
    throw StateError('Crash probe resumed instead of being terminated');
  }

  try {
    await journal.run([directory], (mark) async {
      if (phase == 'staged') rendezvous();
      runSqliteTransaction(db, () {
        for (final name in ['main', 'favorites', 'history']) {
          db.execute('DELETE FROM $name.records');
        }
        mark();
        if (phase == 'transaction') rendezvous();
      }, immediate: true);
      if (phase == 'committed') rendezvous();
    });
  } finally {
    db.dispose();
  }
}
