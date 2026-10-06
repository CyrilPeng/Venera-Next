import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

import 'data_sync_commit.dart';

typedef AppDataImportObserver =
    FutureOr<void> Function(AppDataImportEvent event);

class AppDataImportEvent {
  const AppDataImportEvent(this.phase, this.id, [this.resource]);
  final String phase;
  final String id;
  final String? resource;
}

class AppDataImportReceipt {
  const AppDataImportReceipt({
    required this.id,
    required this.syncOperationId,
    required this.commitState,
    required this.committedAt,
  });
  final String id;
  final String? syncOperationId;
  final DataSyncCommitState commitState;
  final int? committedAt;
}

const _databases = {'history.db', 'local_favorite.db', 'cookie.db'};
const _metadata = {'appdata.json', 'syncdata.json'};
const _sidecars = ['-journal', '-wal', '-shm'];
final _allowed = {
  'comic_source',
  ..._databases,
  for (final name in _databases)
    for (final suffix in _sidecars) name + suffix,
  for (final name in _metadata) ...[name, '$name.bak', '$name.tmp'],
};

/// An import's disk protocol, independent of Flutter and open application stores.
/// The caller must exclude writers and close affected databases before prepare.
class AppDataImportJournal {
  AppDataImportJournal._(this.dataPath, this._db, this._observer);

  factory AppDataImportJournal.open(
    String dataPath, {
    AppDataImportObserver? observer,
  }) {
    final root = Directory(p.normalize(p.absolute(dataPath)));
    root.createSync(recursive: true);
    final resolved = p.normalize(root.resolveSymbolicLinksSync());
    final journalPath = p.join(resolved, '.app-data-import.sqlite');
    for (final suffix in ['', ..._sidecars]) {
      _checkPath(resolved, journalPath + suffix);
    }
    final db = openSqliteDatabase(journalPath);
    try {
      // This journal coordinates files outside SQLite; do not weaken its
      // durable intent/terminal records to the application store defaults.
      db.execute('PRAGMA synchronous = FULL;');
      db.execute('PRAGMA foreign_keys = ON;');
      final version = db.select('PRAGMA user_version;').single.values.first;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported app-data import journal');
      }
      runSqliteTransaction(db, () {
        db.execute('''
          CREATE TABLE IF NOT EXISTS import_operations (
            id TEXT PRIMARY KEY,
            sync_id TEXT,
            phase TEXT NOT NULL,
            committed_at INTEGER,
            resource_manifest TEXT,
            cleaned INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE IF NOT EXISTS import_resources (
            operation_id TEXT NOT NULL REFERENCES import_operations(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            existed INTEGER NOT NULL,
            before_hash TEXT,
            phase TEXT NOT NULL,
            PRIMARY KEY (operation_id, name)
          );
          PRAGMA user_version = 1;
        ''');
      });
      return AppDataImportJournal._(resolved, db, observer);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  final String dataPath;
  final Database _db;
  final AppDataImportObserver? _observer;
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Import journal is closed');
  }

  List<AppDataImportReceipt> get receipts {
    _checkOpen();
    return [
      for (final row in _db.select(
        "SELECT * FROM import_operations WHERE phase IN ('applied', 'rolledBack') ORDER BY rowid",
      ))
        _receipt(row),
    ];
  }

  /// Include unfinished intents: absence of a terminal receipt alone cannot
  /// establish that a sync download never reached the replacement boundary.
  bool containsSyncOperation(String syncOperationId) {
    _checkOpen();
    var found = false;
    for (final row in _db.select('SELECT * FROM import_operations')) {
      _id(row['id']);
      _phase(row);
      final syncId = row['sync_id'];
      if (syncId != null && (syncId is! String || syncId.isEmpty)) {
        throw const FormatException('Invalid import sync identity');
      }
      if (syncId == syncOperationId) {
        if (found) {
          throw const FormatException('Duplicate import sync identity');
        }
        found = true;
      }
    }
    return found;
  }

  /// Check before saving settings or closing application stores. Recovery may
  /// need the current files unchanged and must run before any store is opened.
  void checkReadyForImport() {
    _checkOpen();
    String? recoveryPath;
    try {
      for (final row in _db.select(
        'SELECT * FROM import_operations ORDER BY rowid',
      )) {
        recoveryPath = null;
        final id = _id(row['id']);
        recoveryPath = p.join(dataPath, '.app-data-import-$id');
        if (!const {'applied', 'rolledBack'}.contains(_phase(row))) {
          throw StateError('An earlier import must be recovered first');
        }
      }
    } catch (error, stack) {
      throw DataSyncImportFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        recoveryPath: recoveryPath,
        failures: [
          (stage: 'pending import recovery', error: error, stack: stack),
        ],
      );
    }
  }

  Future<AppDataImportTransaction> prepare({
    required Set<String> resources,
    String? syncOperationId,
  }) async {
    checkReadyForImport();
    if (syncOperationId != null && syncOperationId.trim().isEmpty) {
      throw ArgumentError.value(syncOperationId, 'syncOperationId');
    }
    final names = <String>{
      ...resources,
      for (final name in _metadata) ...[name, '$name.bak', '$name.tmp'],
    };
    for (final name in resources) {
      _checkName(name);
      for (final database in _databases) {
        if (name == database ||
            _sidecars.any((suffix) => name == database + suffix)) {
          names.add(database);
          names.addAll(_sidecars.map((suffix) => database + suffix));
        }
      }
    }
    final sorted = names.toList()..sort();
    final descriptions = <({String name, String kind, bool existed})>[];
    for (final name in sorted) {
      final target = _target(name);
      final kind = name == 'comic_source' ? 'directory' : 'file';
      final type = _type(target);
      if (type != FileSystemEntityType.notFound &&
          type !=
              (kind == 'file'
                  ? FileSystemEntityType.file
                  : FileSystemEntityType.directory)) {
        throw FileSystemException('Unexpected import resource type', target);
      }
      descriptions.add((
        name: name,
        kind: kind,
        existed: type != FileSystemEntityType.notFound,
      ));
    }
    final id = const Uuid().v4();
    final transaction = AppDataImportTransaction._(this, id);
    if (_type(transaction.directoryPath) != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Import directory already exists',
        transaction.directoryPath,
      );
    }
    runSqliteTransaction(_db, () {
      // Recheck under the write lock: a different journal connection may have
      // prepared an operation since the initial read-only admission check.
      checkReadyForImport();
      _db.execute(
        "INSERT INTO import_operations(id, sync_id, phase) VALUES (?, ?, 'preparing')",
        [id, syncOperationId],
      );
      for (final entry in descriptions) {
        _db.execute(
          "INSERT INTO import_resources(operation_id,name,kind,existed,phase) VALUES(?,?,?,?, 'prepared')",
          [id, entry.name, entry.kind, entry.existed ? 1 : 0],
        );
      }
    }, immediate: true);
    try {
      final directory = transaction.directoryPath;
      if (_type(directory) != FileSystemEntityType.notFound) {
        throw FileSystemException('Import directory already exists', directory);
      }
      Directory(directory).createSync();
      for (final name in ['before', 'staged', 'discarded']) {
        Directory(p.join(directory, name)).createSync();
      }
      for (final entry in descriptions) {
        if (!entry.existed) continue;
        final source = _target(entry.name);
        final before = await _fingerprint(source);
        final backup = transaction._backup(entry.name);
        await _copy(source, backup);
        final after = await _fingerprint(backup);
        if (before != after || before != await _fingerprint(source)) {
          throw FileSystemException(
            'Import resource changed during backup',
            source,
          );
        }
        _db.execute(
          'UPDATE import_resources SET before_hash=? WHERE operation_id=? AND name=?',
          [before, id, entry.name],
        );
        await transaction._event('backedUp', entry.name);
      }
      final manifest = _resourceManifest(
        _db.select(
          'SELECT * FROM import_resources WHERE operation_id=? ORDER BY name',
          [id],
        ),
      );
      _db.execute(
        "UPDATE import_operations SET phase='prepared', resource_manifest=? WHERE id=?",
        [manifest, id],
      );
      await transaction._event('prepared');
      return transaction;
    } catch (error, stack) {
      final failures = <DataSyncDiagnostic>[
        (stage: 'prepare import', error: error, stack: stack),
      ];
      // Preparation has not touched any live resource. Failed backup/observer
      // work may leave owned artifacts but cannot require restoring live data.
      try {
        _db.execute(
          "UPDATE import_operations SET phase='rolledBack' WHERE id=?",
          [id],
        );
        await cleanup(id);
      } catch (cleanupError, cleanupStack) {
        failures.add((
          stage: 'clean failed import preparation',
          error: cleanupError,
          stack: cleanupStack,
        ));
      }
      throw DataSyncImportFailure(
        commitState: DataSyncCommitState.notApplied,
        failures: failures,
        recoveryPath: transaction.directoryPath,
      );
    }
  }

  /// Startup only: no application writer or affected database may be open.
  Future<List<AppDataImportReceipt>> recoverPending() async {
    _checkOpen();
    final result = <AppDataImportReceipt>[];
    for (final original in _db.select(
      'SELECT * FROM import_operations ORDER BY rowid',
    )) {
      final id = _id(original['id']);
      final transaction = AppDataImportTransaction._(this, id);
      final phase = _phase(original);
      if (phase == 'preparing') {
        // No live mutation is allowed before the durable prepared transition.
        _db.execute(
          "UPDATE import_operations SET phase='rolledBack' WHERE id=?",
          [id],
        );
      } else if (phase != 'applied' && phase != 'rolledBack') {
        final failures = await transaction.restore();
        if (failures.isNotEmpty) {
          throw DataSyncImportFailure(
            commitState: DataSyncCommitState.recoveryRequired,
            failures: failures,
            recoveryPath: transaction.directoryPath,
          );
        }
        await transaction.markRolledBack();
      }
      final receipt = _receipt(_operation(id)!);
      try {
        await cleanup(id);
      } catch (error, stack) {
        throw DataSyncImportFailure(
          commitState: receipt.commitState,
          failures: [
            (stage: 'clean recovered import', error: error, stack: stack),
          ],
          recoveryPath: transaction.directoryPath,
        );
      }
      result.add(receipt);
    }
    return result;
  }

  /// Terminal cleanup never reads, replaces or removes a live resource.
  Future<void> cleanup(String id) async {
    _checkOpen();
    final row = _operation(_id(id));
    if (row == null) return;
    if (!const {'applied', 'rolledBack'}.contains(_phase(row))) {
      throw StateError('Cannot clean an unfinished import');
    }
    final transaction = AppDataImportTransaction._(this, id);
    final directory = transaction.directoryPath;
    if (_type(directory) != FileSystemEntityType.notFound) {
      _checkTree(directory);
      for (final entity in Directory(directory).listSync(followLinks: false)) {
        await _deleteOwned(directory, entity.path);
        await transaction._event('cleanupResource', p.basename(entity.path));
      }
      _checkPath(dataPath, directory);
      Directory(directory).deleteSync();
    }
    _db.execute('UPDATE import_operations SET cleaned=1 WHERE id=?', [id]);
    await transaction._event('cleaned');
    if (row['sync_id'] == null) {
      _db.execute('DELETE FROM import_operations WHERE id=?', [id]);
    }
  }

  /// The sync owner first persists its terminal state and clears its marker.
  Future<void> acknowledge(String id) async {
    _checkOpen();
    if (_operation(_id(id)) == null) return;
    await cleanup(id);
    _db.execute('DELETE FROM import_operations WHERE id=?', [id]);
  }

  void close() {
    if (_closed) return;
    _db.dispose();
    _closed = true;
  }

  Row? _operation(String id) {
    _checkOpen();
    final rows = _db.select('SELECT * FROM import_operations WHERE id=?', [id]);
    return rows.isEmpty ? null : rows.single;
  }

  List<Row> _resources(String id) {
    final operation =
        _operation(id) ??
        (throw StateError('Import transaction has been acknowledged'));
    final rows = _db.select(
      'SELECT * FROM import_resources WHERE operation_id=? ORDER BY name',
      [id],
    );
    for (final row in rows) {
      _checkName(row['name']);
      if (!const {'file', 'directory'}.contains(row['kind']) ||
          (row['kind'] == 'directory') != (row['name'] == 'comic_source') ||
          !const {0, 1}.contains(row['existed']) ||
          !const {
            'prepared',
            'changing',
            'installed',
            'restoring',
            'restored',
          }.contains(row['phase'])) {
        throw const FormatException('Invalid import resource journal');
      }
      final hash = row['before_hash'];
      if (_phase(operation) != 'preparing' &&
          (row['existed'] == 1
              ? hash is! String || !RegExp('^[a-f0-9]{64}\$').hasMatch(hash)
              : hash != null)) {
        throw const FormatException('Invalid import backup fingerprint');
      }
    }
    final names = rows.map((row) => row['name']).toSet();
    if (!_metadata.every(
          (name) =>
              names.contains(name) &&
              names.contains('$name.bak') &&
              names.contains('$name.tmp'),
        ) ||
        !_databases.every(
          (name) =>
              !names.contains(name) ||
              _sidecars.every((suffix) => names.contains(name + suffix)),
        )) {
      throw const FormatException('Incomplete import resource journal');
    }
    if (_phase(operation) != 'preparing' &&
        operation['resource_manifest'] != _resourceManifest(rows)) {
      throw const FormatException('Import resource manifest does not match');
    }
    return rows;
  }

  AppDataImportReceipt _receipt(Row row) {
    final phase = _phase(row);
    if (!const {'applied', 'rolledBack'}.contains(phase)) {
      throw StateError('Import has no terminal receipt');
    }
    final syncId = row['sync_id'];
    final time = row['committed_at'];
    if ((syncId != null && (syncId is! String || syncId.isEmpty)) ||
        (phase == 'applied'
            ? !isValidDataSyncCommitTime(time)
            : time != null)) {
      throw const FormatException('Invalid import receipt');
    }
    return AppDataImportReceipt(
      id: _id(row['id']),
      syncOperationId: syncId as String?,
      commitState: phase == 'applied'
          ? DataSyncCommitState.applied
          : DataSyncCommitState.notApplied,
      committedAt: time as int?,
    );
  }

  String _target(String resource) {
    _checkName(resource);
    final target = p.join(dataPath, resource);
    _checkPath(dataPath, target);
    return target;
  }
}

class AppDataImportTransaction {
  AppDataImportTransaction._(this._journal, this.id);
  final AppDataImportJournal _journal;
  final String id;

  String get directoryPath =>
      p.join(_journal.dataPath, '.app-data-import-${_id(id)}');
  Row get _row =>
      _journal._operation(id) ??
      (throw StateError('Import transaction has been acknowledged'));
  String? get syncOperationId => _row['sync_id'] as String?;
  int? get committedAt => _row['committed_at'] as int?;
  DataSyncCommitState get state => switch (_phase(_row)) {
    'applied' => DataSyncCommitState.applied,
    'preparing' || 'prepared' || 'rolledBack' => DataSyncCommitState.notApplied,
    _ => DataSyncCommitState.recoveryRequired,
  };

  Set<String> get unrestoredResources {
    final names = {
      for (final row in _journal._resources(id))
        if (row['phase'] != 'prepared' && row['phase'] != 'restored')
          row['name'] as String,
    };
    for (final database in _databases) {
      if (_sidecars.any((suffix) => names.contains(database + suffix))) {
        names.add(database);
      }
    }
    return names;
  }

  Future<void> _event(String phase, [String? resource]) async {
    await _journal._observer?.call(AppDataImportEvent(phase, id, resource));
  }

  String _backup(String name) => _owned('before', name);
  String _owned(String folder, String name) {
    _checkName(name);
    final result = p.join(directoryPath, folder, name);
    _checkPath(_journal.dataPath, result);
    return result;
  }

  List<Row> _group(String resource) {
    _checkName(resource);
    final names = {
      resource,
      if (_databases.contains(resource))
        for (final suffix in _sidecars) resource + suffix,
      if (_metadata.contains(resource)) ...['$resource.bak', '$resource.tmp'],
    };
    final rows = _journal
        ._resources(id)
        .where((row) => names.contains(row['name']))
        .toList();
    if (!rows.any((row) => row['name'] == resource)) {
      throw StateError('Resource was not prepared: $resource');
    }
    return rows;
  }

  Future<void> _verifyBackup(Row row) async {
    if (row['existed'] == 0) return;
    final hash = row['before_hash'];
    final path = _backup(row['name'] as String);
    if (hash is! String || await _fingerprint(path) != hash) {
      throw FileSystemException('Import backup is missing or damaged', path);
    }
  }

  Future<void> markChanging(String resource) async {
    final phase = _phase(_row);
    if (!const {'prepared', 'applying'}.contains(phase)) {
      throw StateError('Import is not accepting changes');
    }
    final rows = _group(resource);
    for (final row in rows.where((row) => row['phase'] == 'prepared')) {
      await _verifyBackup(row);
      final target = _journal._target(row['name'] as String);
      if (row['existed'] == 0
          ? _type(target) != FileSystemEntityType.notFound
          : await _fingerprint(target) != row['before_hash']) {
        throw FileSystemException(
          'Import resource changed after preparation',
          target,
        );
      }
    }
    runSqliteTransaction(_journal._db, () {
      _journal._db.execute(
        "UPDATE import_operations SET phase='applying' WHERE id=?",
        [id],
      );
      for (final row in rows) {
        if (row['phase'] == 'prepared') {
          _journal._db.execute(
            "UPDATE import_resources SET phase='changing' WHERE operation_id=? AND name=?",
            [id, row['name']],
          );
        }
      }
    });
    await _event('changing', resource);
  }

  Future<void> replaceFile(String resource, File source) =>
      _replace(resource, source.path, 'file');

  Future<void> replaceDirectory(String resource, Directory source) =>
      _replace(resource, source.path, 'directory');

  Future<void> _replace(String resource, String source, String kind) async {
    final row = _group(resource).firstWhere((row) => row['name'] == resource);
    if (row['kind'] != kind) throw ArgumentError('Resource type mismatch');
    final staged = _owned('staged', resource);
    if (_type(staged) != FileSystemEntityType.notFound) {
      throw FileSystemException('Import staging is already occupied', staged);
    }
    await _copy(source, staged);
    await markChanging(resource);
    final target = _journal._target(resource);
    if (_databases.contains(resource)) {
      for (final suffix in _sidecars) {
        await _retire(_journal._target(resource + suffix));
      }
    }
    await _retire(target);
    await _event('targetRemoved', resource);
    _rename(staged, target);
    _journal._db.execute(
      "UPDATE import_resources SET phase='installed' WHERE operation_id=? AND name=?",
      [id, resource],
    );
    await _event('replaced', resource);
  }

  Future<void> _retire(String target) async {
    _checkPath(_journal.dataPath, target);
    if (_type(target) == FileSystemEntityType.notFound) return;
    _checkTree(target);
    final discarded = p.join(
      directoryPath,
      'discarded',
      '${p.basename(target)}-${const Uuid().v4()}',
    );
    _checkPath(_journal.dataPath, discarded);
    _rename(target, discarded);
  }

  /// Copies from immutable backups on every attempt until markRolledBack.
  /// A failed DB group leaves its base in unrestoredResources.
  Future<List<DataSyncDiagnostic>> restore({
    Set<String> skip = const {},
  }) async {
    if (!const {'prepared', 'applying', 'rollingBack'}.contains(_phase(_row))) {
      throw StateError('Cannot restore a terminal import');
    }
    for (final name in skip) {
      _checkName(name);
    }
    final rows = _journal
        ._resources(id)
        .where((row) => row['phase'] != 'prepared')
        .toList();
    final skipped = {
      ...skip,
      for (final name in skip)
        if (_databases.contains(name))
          for (final suffix in _sidecars) name + suffix,
    };
    runSqliteTransaction(_journal._db, () {
      _journal._db.execute(
        "UPDATE import_operations SET phase='rollingBack' WHERE id=?",
        [id],
      );
      for (final row in rows) {
        _journal._db.execute(
          "UPDATE import_resources SET phase='restoring' WHERE operation_id=? AND name=?",
          [id, row['name']],
        );
      }
    });
    final groups = <List<Row>>[];
    for (final database in _databases) {
      final group = rows
          .where(
            (row) =>
                row['name'] == database ||
                _sidecars.any((suffix) => row['name'] == database + suffix),
          )
          .toList();
      if (group.isNotEmpty) groups.add(group);
    }
    groups.addAll(
      rows
          .where(
            (row) => !_databases.any(
              (database) =>
                  row['name'] == database ||
                  _sidecars.any((suffix) => row['name'] == database + suffix),
            ),
          )
          .map((row) => [row]),
    );
    final failures = <DataSyncDiagnostic>[];
    for (final group in groups) {
      if (group.any((row) => skipped.contains(row['name']))) continue;
      final name = group.first['name'] as String;
      try {
        for (final row in group) {
          await _verifyBackup(row);
        }
        // Old sidecars cannot be installed against the new main file. First
        // isolate all sidecars from this uncommitted database epoch.
        for (final row in group.where(
          (row) => _databases.any(
            (database) =>
                _sidecars.any((suffix) => row['name'] == database + suffix),
          ),
        )) {
          await _retire(_journal._target(row['name'] as String));
        }
        group.sort((a, b) {
          final aMain = _databases.contains(a['name']);
          final bMain = _databases.contains(b['name']);
          return aMain == bMain ? 0 : (aMain ? -1 : 1);
        });
        for (final row in group) {
          await _restoreOne(row);
        }
      } catch (error, stack) {
        // A sibling may have restored successfully. The entire DB group still
        // cannot be reopened while its remaining sidecars are unresolved.
        for (final row in group) {
          _journal._db.execute(
            "UPDATE import_resources SET phase='restoring' WHERE operation_id=? AND name=?",
            [id, row['name']],
          );
        }
        failures.add((stage: 'restore $name', error: error, stack: stack));
      }
    }
    return failures;
  }

  Future<void> _restoreOne(Row row) async {
    final resource = row['name'] as String;
    await _event('restoring', resource);
    final target = _journal._target(resource);
    final staged = _owned('staged', resource);
    await _deleteOwned(directoryPath, staged);
    if (row['existed'] == 1) {
      await _copy(_backup(resource), staged);
      if (await _fingerprint(staged) != row['before_hash']) {
        throw FileSystemException(
          'Restored import copy failed verification',
          staged,
        );
      }
    }
    await _retire(target);
    if (row['existed'] == 1) _rename(staged, target);
    _journal._db.execute(
      "UPDATE import_resources SET phase='restored' WHERE operation_id=? AND name=?",
      [id, resource],
    );
    await _event('restored', resource);
  }

  Future<void> markRolledBack() async {
    if (!const {
      'prepared',
      'rollingBack',
      'rolledBack',
    }.contains(_phase(_row))) {
      throw StateError('Import has not been restored');
    }
    if (unrestoredResources.isNotEmpty) {
      throw StateError('Import still has unrestored resources');
    }
    _journal._db.execute(
      "UPDATE import_operations SET phase='rolledBack' WHERE id=?",
      [id],
    );
    await _event('rolledBack');
  }

  Future<void> markApplied(int timestamp) async {
    if (!isValidDataSyncCommitTime(timestamp)) {
      throw ArgumentError.value(
        timestamp,
        'timestamp',
        'Invalid import commit time',
      );
    }
    final phase = _phase(_row);
    if (phase == 'applied') {
      if (committedAt != timestamp) {
        throw StateError('Import time is immutable');
      }
      return;
    }
    if (!const {'prepared', 'applying'}.contains(phase)) {
      throw StateError('Import cannot commit after rollback');
    }
    _journal._resources(id);
    await _event('beforeApplied');
    _journal._db.execute(
      "UPDATE import_operations SET phase='applied', committed_at=? WHERE id=?",
      [timestamp, id],
    );
    await _event('applied');
  }

  Future<void> cleanup() => _journal.cleanup(id);
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(
        '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$',
      ).hasMatch(value)) {
    throw const FormatException('Invalid import operation identity');
  }
  return value;
}

String _phase(Row row) {
  final phase = row['phase'];
  if (phase is! String ||
      !const {
        'preparing',
        'prepared',
        'applying',
        'rollingBack',
        'rolledBack',
        'applied',
      }.contains(phase)) {
    throw const FormatException('Invalid import operation phase');
  }
  return phase;
}

void _checkName(Object? name) {
  if (name is! String || !_allowed.contains(name)) {
    throw ArgumentError.value(name, 'resource', 'Unknown import resource');
  }
}

String _resourceManifest(List<Row> rows) => jsonEncode([
  for (final row in rows)
    [row['name'], row['kind'], row['existed'], row['before_hash']],
]);

void _checkDirectoryLocation(String path) {
  if (_type(path) != FileSystemEntityType.directory ||
      !_samePath(path, Directory(path).resolveSymbolicLinksSync())) {
    throw FileSystemException(
      'Import destination parent is missing or aliased',
      path,
    );
  }
}

FileSystemEntityType _type(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);

bool _samePath(String first, String second) {
  first = p.normalize(p.absolute(first));
  second = p.normalize(p.absolute(second));
  return Platform.isWindows
      ? first.toLowerCase() == second.toLowerCase()
      : first == second;
}

void _checkPath(String root, String path) {
  final absolute = p.normalize(p.absolute(path));
  if (!_samePath(root, absolute) && !p.isWithin(root, absolute)) {
    throw FileSystemException('Import path escapes its data directory', path);
  }
  var current = absolute;
  while (!_samePath(current, root)) {
    final type = _type(current);
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('Import paths cannot contain links', current);
    }
    if (type != FileSystemEntityType.notFound) {
      final resolved = type == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinksSync()
          : File(current).resolveSymbolicLinksSync();
      if (!_samePath(current, resolved)) {
        throw FileSystemException(
          'Import paths cannot cross filesystem aliases',
          current,
        );
      }
    }
    current = p.dirname(current);
  }
}

void _checkTree(String path) {
  final absolute = p.normalize(p.absolute(path));
  final type = _type(absolute);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.directory) {
    throw FileSystemException('Unsupported import filesystem entry', path);
  }
  final resolved = type == FileSystemEntityType.directory
      ? Directory(absolute).resolveSymbolicLinksSync()
      : File(absolute).resolveSymbolicLinksSync();
  if (!_samePath(absolute, resolved)) {
    throw FileSystemException('Import filesystem entry is an alias', path);
  }
  if (type == FileSystemEntityType.directory) {
    for (final child in Directory(absolute).listSync(followLinks: false)) {
      _checkTree(child.path);
    }
  }
}

Future<String?> _fingerprint(String path) async {
  _checkTree(path);
  final type = _type(path);
  if (type == FileSystemEntityType.notFound) return null;
  if (type == FileSystemEntityType.file) {
    return (await sha256.bind(File(path).openRead()).first).toString();
  }
  final entries = Directory(path).listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  final manifest = <Object>[];
  for (final entry in entries) {
    manifest.add([
      p.relative(entry.path, from: path),
      entry is Directory ? 'directory' : await _fingerprint(entry.path),
    ]);
  }
  return sha256.convert(utf8.encode(jsonEncode(manifest))).toString();
}

Future<void> _copy(String source, String destination) async {
  _checkTree(source);
  _checkDirectoryLocation(p.dirname(destination));
  if (_type(source) == FileSystemEntityType.file) {
    await File(source).copy(destination);
    final file = await File(destination).open(mode: FileMode.append);
    try {
      await file.flush();
    } finally {
      await file.close();
    }
  } else if (_type(source) == FileSystemEntityType.directory) {
    Directory(destination).createSync();
    for (final entry in Directory(source).listSync(followLinks: false)) {
      await _copy(entry.path, p.join(destination, p.basename(entry.path)));
    }
  } else {
    throw FileSystemException('Import source is missing', source);
  }
}

void _rename(String source, String destination) {
  _checkTree(source);
  _checkDirectoryLocation(p.dirname(destination));
  if (_type(destination) != FileSystemEntityType.notFound) {
    throw FileSystemException('Import destination is occupied', destination);
  }
  if (_type(source) == FileSystemEntityType.directory) {
    Directory(source).renameSync(destination);
  } else {
    File(source).renameSync(destination);
  }
}

Future<void> _deleteOwned(String root, String path) async {
  if (!p.isWithin(root, path)) {
    throw FileSystemException('Cannot remove an unowned import path', path);
  }
  _checkPath(root, path);
  _checkTree(path);
  final type = _type(path);
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type == FileSystemEntityType.file) {
    await File(path).delete();
  }
}
