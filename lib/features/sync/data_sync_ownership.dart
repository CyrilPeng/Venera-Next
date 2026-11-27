import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_library;
import 'package:sqlite3/sqlite3.dart';
// sqlite3 2.9.4 exposes no public way to replace its Dart finalizer. Keep this
// workaround limited to private lease connections with no hooks or live SQL
// statements; their native close must also run when an engine isolate exits.
// ignore: implementation_imports
import 'package:sqlite3/src/implementation/finalizer.dart' as sqlite_finalizer;

import 'data_sync_commit.dart';

/// One service owns recovery, markers and transfers until its accepted work has
/// drained. Ordinary application writers still use their own data admission.
abstract interface class DataSyncOwnership {
  void acquire();
  void release();
}

/// A dedicated SQLite transaction arbitrates across connections, isolates and
/// processes. No timeout/age/pid inference and no deletion of the lock file.
class SqliteDataSyncOwnership implements DataSyncOwnership, Finalizable {
  SqliteDataSyncOwnership(
    this.dataPath, {
    Database Function(String)? openDatabase,
  }) : _openDatabase = openDatabase ?? sqlite3.open,
       _useNativeFinalizer = openDatabase == null,
       _fileName = fileName;

  /// The core holds a distinct lease from startup recovery through final store
  /// closure. This also covers headless work that never starts a sync service.
  /// A second process cannot keep stale live handles across data replacement.
  SqliteDataSyncOwnership.applicationData(
    this.dataPath, {
    Database Function(String)? openDatabase,
  }) : _openDatabase = openDatabase ?? sqlite3.open,
       _useNativeFinalizer = openDatabase == null,
       _fileName = applicationDataFileName;

  static const fileName = '.data-sync-owner.sqlite';
  static const applicationDataFileName = '.app-data-owner.sqlite';
  static const _schema =
      'CREATE TABLE sync_owner (id INTEGER PRIMARY KEY CHECK(id = 1))';
  final String Function() dataPath;
  final Database Function(String) _openDatabase;
  final bool _useNativeFinalizer;
  final String _fileName;
  Database? _database;
  NativeFinalizer? _databaseFinalizer;
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
    final path = p.join(root, _fileName);
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
      if (_useNativeFinalizer) {
        final finalizer = _databaseFinalizer = _ownershipDatabaseFinalizer;
        finalizer.attach(this, db.handle.cast<Void>(), detach: db);
        // Both finalizers must never close the same handle. The owner keeps the
        // database reachable while live, and native finalization now covers
        // abrupt isolate exit where Dart finally/finalizer callbacks cannot run.
        sqlite_finalizer.disposeFinalizer.detach(db);
      }
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
    final finalizer = _databaseFinalizer;
    // Detach before explicit close so isolate shutdown cannot close a freed
    // handle again. A reported failure still owns that handle and its cleanup.
    finalizer?.detach(database);
    try {
      database.dispose();
    } catch (_) {
      finalizer?.attach(this, database.handle.cast<Void>(), detach: database);
      rethrow;
    }
    _databaseFinalizer = null;
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

// Native finalization ignores the integer return value of close_v2. Dedicated
// connections have no Dart hooks or outstanding statements, so it can safely
// roll back and release their transaction on a native finalizer thread.
final _ownershipDatabaseFinalizer = NativeFinalizer(
  sqlite_library.open
      .openSqlite()
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('sqlite3_close_v2')
      .cast(),
);
