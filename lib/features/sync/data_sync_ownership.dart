import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'data_sync_commit.dart';

/// One service owns recovery, markers and transfers until its accepted work has
/// drained. Ordinary application writers still use their own data admission.
abstract interface class DataSyncOwnership {
  void acquire();
  void release();
}

/// A dedicated SQLite transaction arbitrates across connections, isolates and
/// processes. No timeout/age/pid inference and no deletion of the lock file.
class SqliteDataSyncOwnership implements DataSyncOwnership {
  SqliteDataSyncOwnership(
    this.dataPath, {
    Database Function(String)? openDatabase,
  }) : _openDatabase = openDatabase ?? sqlite3.open;

  static const fileName = '.data-sync-owner.sqlite';
  static const _schema =
      'CREATE TABLE sync_owner (id INTEGER PRIMARY KEY CHECK(id = 1))';
  final String Function() dataPath;
  final Database Function(String) _openDatabase;
  Database? _database;
  String? _root;
  bool _acquired = false;
  bool _retired = false;

  @override
  void acquire() {
    if (_retired) throw StateError('Sync ownership has been retired');
    final directory = Directory(p.normalize(p.absolute(dataPath())))
      ..createSync(recursive: true);
    final root = p.normalize(directory.resolveSymbolicLinksSync());
    if (_acquired) {
      if (!p.equals(root, _root!)) {
        throw StateError('Sync ownership belongs to another data directory');
      }
      return;
    }
    // A failed acquisition may itself have failed to close. Retry that exact
    // connection before opening another one; never abandon an owned handle.
    _closeConnection();
    final path = p.join(root, fileName);
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final type = FileSystemEntity.typeSync(path + suffix, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException('Invalid sync ownership path', path + suffix);
      }
    }
    final db = _database = _openDatabase(path);
    _root = root;
    try {
      db.execute('PRAGMA busy_timeout = 0;');
      db.execute('PRAGMA journal_mode = DELETE;');
      db.execute('BEGIN EXCLUSIVE;');
      final version = db.select('PRAGMA user_version').single.values.single;
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'",
      );
      if (version == 0 && tables.isEmpty) {
        db.execute('$_schema; PRAGMA user_version = 1; COMMIT;');
        // A contender can win between initialization and reacquisition. That is
        // a normal failed admission, before any sync metadata can be touched.
        db.execute('BEGIN EXCLUSIVE;');
      }
      // Recheck after reacquisition as another connection may have changed the
      // database during initialization. Unknown schemas are never repurposed.
      final schema = db.select(
        "SELECT type, name, sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'",
      );
      if (db.select('PRAGMA user_version').single.values.single != 1 ||
          schema.length != 1 ||
          schema.single['type'] != 'table' ||
          schema.single['name'] != 'sync_owner' ||
          schema.single['sql'] != _schema) {
        throw const FormatException('Unrecognized sync ownership database');
      }
      _acquired = true;
    } catch (error, stack) {
      try {
        _closeConnection();
      } catch (closeError, closeStack) {
        throw DataSyncFailure(
          commitState: DataSyncCommitState.notApplied,
          failures: [
            (stage: 'acquire sync ownership', error: error, stack: stack),
            (
              stage: 'close failed sync ownership',
              error: closeError,
              stack: closeStack,
            ),
          ],
        );
      }
      rethrow;
    }
  }

  void _closeConnection() {
    final database = _database;
    if (database == null) return;
    // Closing rolls back and releases the transaction. Do not unlock early or
    // forget the connection when its close reports failure.
    database.dispose();
    _database = null;
    _root = null;
    _acquired = false;
  }

  @override
  void release() {
    _retired = true;
    _closeConnection();
  }
}
