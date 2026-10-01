import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

/// Produces a standalone SQLite backup, including committed WAL contents.
/// The destination must be new and exclusively owned by the caller.
Future<void> createSqliteSnapshot(
  String sourcePath,
  String destinationPath,
) async {
  final target = File(destinationPath);
  if (target.existsSync()) {
    throw StateError('Snapshot destination already exists');
  }
  Database? source;
  Database? destination;
  var ownsTarget = false;
  try {
    try {
      source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
      source.execute('PRAGMA busy_timeout = 5000;');
      source.execute('BEGIN;');
      // Pin a read snapshot before starting the asynchronous backup stream.
      // The private destination has no competing connections.
      source.select('SELECT name FROM sqlite_master LIMIT 1;');
      ownsTarget = true;
      destination = sqlite3.open(destinationPath);
      await source.backup(destination, nPage: -1).drain<void>();
    } finally {
      destination?.dispose();
      source?.dispose();
    }
  } catch (_) {
    if (ownsTarget) {
      try {
        if (target.existsSync()) target.deleteSync();
      } catch (_) {
        // Preserve the original backup failure; caller owns staging cleanup.
      }
    }
    rethrow;
  }
}
