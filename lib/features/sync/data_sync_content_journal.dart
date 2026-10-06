import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/app_data_sync_fields.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

import 'data_sync_content.dart';
import 'data_sync_commit.dart';

class DataSyncContentScope {
  DataSyncContentScope({
    required this.endpoint,
    required String excludedFields,
    required this.archiveSyncEnabled,
  }) : excludedFields = (splitAppDataFields(
         excludedFields,
       ).toSet().toList()..sort()).join(',');

  final String endpoint;
  final String excludedFields;
  final bool archiveSyncEnabled;
  bool get hasImportOnlyFields =>
      archiveSyncEnabled &&
      splitAppDataFields(
        excludedFields,
      ).any(appDataOptionalArchiveFields.contains);
  String get id => _digest(jsonEncode(toJson()));
  Map<String, Object?> toJson() => {
    'endpoint': endpoint,
    'excludedFields': excludedFields,
    'archiveSyncEnabled': archiveSyncEnabled,
  };
  factory DataSyncContentScope.fromJson(Map<String, dynamic> json) {
    if (!_hash.hasMatch(json['endpoint'] as String? ?? '') ||
        json['excludedFields'] is! String ||
        json['archiveSyncEnabled'] is! bool) {
      throw const FormatException('Invalid sync content scope');
    }
    return DataSyncContentScope(
      endpoint: json['endpoint'] as String,
      excludedFields: json['excludedFields'] as String,
      archiveSyncEnabled: json['archiveSyncEnabled'] as bool,
    );
  }
}

class DataSyncContentRecord {
  DataSyncContentRecord._(this.sequence, this.payload);
  final int sequence;
  final Map<String, dynamic> payload;
  String get id => payload['id'] as String;
  String get root => payload['root'] as String;
  String get direction => payload['direction'] as String;
  String get before => payload['before'] as String;
  String? get after => payload['after'] as String?;
  String? get archiveHash => payload['archiveHash'] as String?;
  bool get confirmed => payload['confirmed'] == true;
  DataSyncCommitState? get completedState =>
      switch (payload['completedState']) {
        'applied' => DataSyncCommitState.applied,
        'notApplied' => DataSyncCommitState.notApplied,
        _ => confirmed ? DataSyncCommitState.applied : null,
      };
  DataSyncContentScope get scope =>
      DataSyncContentScope.fromJson(payload['scope'] as Map<String, dynamic>);
}

final _hash = RegExp(r'^[0-9a-f]{64}$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

/// A candidate is recorded before a transfer can commit. Only a verified
/// terminal receipt can promote it; promotion and its sequence are atomic.
/// No business data or credentials are stored here, and the file is not exported.
class DataSyncContentJournal {
  DataSyncContentJournal._(this.root, this._db);
  static const fileName = '.data-sync-content.sqlite';
  final String root;
  final Database _db;
  bool _closed = false;

  factory DataSyncContentJournal.open(String dataPath) {
    final directory = Directory(p.normalize(p.absolute(dataPath)))
      ..createSync(recursive: true);
    final root = p.normalize(directory.resolveSymbolicLinksSync());
    final path = p.join(root, fileName);
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final type = FileSystemEntity.typeSync(path + suffix, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Invalid sync content journal path',
          path + suffix,
        );
      }
    }
    final db = openSqliteDatabase(path);
    try {
      db.execute('PRAGMA synchronous = FULL; PRAGMA secure_delete = ON;');
      final version = db.select('PRAGMA user_version').single.values.single;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported sync content journal');
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS content_operations (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT UNIQUE NOT NULL,
          scope TEXT NOT NULL,
          payload TEXT NOT NULL,
          digest TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS content_baselines (
          scope TEXT PRIMARY KEY,
          sequence INTEGER NOT NULL,
          operation_id TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          digest TEXT NOT NULL
        );
        PRAGMA user_version = 1;
      ''');
      return DataSyncContentJournal._(root, db);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Sync content journal is closed');
  }

  List<DataSyncContentRecord> get records {
    _checkOpen();
    return [
      for (final row in _db.select(
        'SELECT id FROM content_operations ORDER BY sequence',
      ))
        lookup(row['id'] as String)!,
    ];
  }

  DataSyncContentRecord? lookup(String id) {
    _checkOpen();
    final rows = _db.select('SELECT * FROM content_operations WHERE id = ?', [
      id,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final payload = row['payload'] as String;
    if (_digest(payload) != row['digest']) {
      throw const FormatException('Sync content record digest mismatch');
    }
    final decoded = jsonDecode(payload) as Map<String, dynamic>;
    final record = DataSyncContentRecord._(row['sequence'] as int, decoded);
    if (![1, 2].contains(decoded['version']) ||
        record.id != id ||
        !_uuid.hasMatch(id) ||
        record.root != root ||
        record.scope.id != row['scope'] ||
        !['upload', 'download'].contains(record.direction) ||
        !_hash.hasMatch(record.before) ||
        (record.after != null && !_hash.hasMatch(record.after!)) ||
        (record.archiveHash != null && !_hash.hasMatch(record.archiveHash!)) ||
        (record.direction == 'download' && record.archiveHash != null) ||
        (record.direction == 'upload' &&
            record.after != null &&
            record.archiveHash == null) ||
        decoded['confirmed'] is! bool ||
        (decoded['version'] == 1 && decoded.containsKey('completedState')) ||
        (decoded['version'] == 2 &&
            (!decoded.containsKey('completedState') ||
                ![
                  null,
                  'applied',
                  'notApplied',
                ].contains(decoded['completedState']) ||
                (decoded['completedState'] == 'applied') !=
                    record.confirmed)) ||
        (record.confirmed && record.after == null)) {
      throw const FormatException('Invalid sync content record');
    }
    return record;
  }

  void begin({
    required String id,
    required String direction,
    required DataSyncContentScope scope,
    required String before,
  }) {
    _checkOpen();
    if (!_uuid.hasMatch(id) ||
        !_hash.hasMatch(scope.endpoint) ||
        !['upload', 'download'].contains(direction) ||
        !_hash.hasMatch(before)) {
      throw const FormatException('Invalid sync content preparation');
    }
    if (lookup(id) != null) {
      throw StateError('Sync content operation already exists');
    }
    final payload = jsonEncode({
      'version': 2,
      'id': id,
      'root': root,
      'direction': direction,
      'scope': scope.toJson(),
      'before': before,
      'after': null,
      'archiveHash': null,
      'confirmed': false,
      'completedState': null,
    });
    _db.execute(
      'INSERT INTO content_operations (id, scope, payload, digest) VALUES (?, ?, ?, ?)',
      [id, scope.id, payload, _digest(payload)],
    );
  }

  void recordSnapshot(String id, String fingerprint, {String? archiveHash}) {
    final record =
        lookup(id) ?? (throw StateError('Missing sync content operation'));
    if (record.completedState == DataSyncCommitState.notApplied) {
      throw StateError('Sync content operation did not apply');
    }
    if (!_hash.hasMatch(fingerprint) ||
        (archiveHash != null && !_hash.hasMatch(archiveHash)) ||
        (record.direction == 'upload' && archiveHash == null) ||
        (record.direction == 'download' && archiveHash != null)) {
      throw const FormatException('Invalid synchronized content fingerprint');
    }
    if (record.after != null &&
        (record.after != fingerprint || record.archiveHash != archiveHash)) {
      throw StateError('Sync content candidate is immutable');
    }
    record.payload['after'] = fingerprint;
    record.payload['archiveHash'] = archiveHash;
    _save(record);
  }

  void verifyBeforeImport(String id, String current) {
    final record =
        lookup(id) ?? (throw StateError('Missing download content guard'));
    if (record.direction != 'download' ||
        record.completedState != null ||
        current != record.before) {
      throw const DataSyncContentConflict();
    }
  }

  String? baseline(DataSyncContentScope scope) {
    _checkOpen();
    final rows = _db.select('SELECT * FROM content_baselines WHERE scope = ?', [
      scope.id,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final hash = row['fingerprint'] as String;
    final identity = jsonEncode([
      root,
      scope.id,
      row['sequence'],
      row['operation_id'],
      hash,
    ]);
    if (!_hash.hasMatch(hash) || _digest(identity) != row['digest']) {
      throw const FormatException('Sync content baseline digest mismatch');
    }
    return hash;
  }

  /// Call only after validating the matching transfer's durable applied receipt.
  void confirm(String id) {
    _checkOpen();
    runSqliteTransaction(_db, () {
      final record =
          lookup(id) ?? (throw StateError('Missing sync content candidate'));
      if (record.completedState == DataSyncCommitState.notApplied) {
        throw StateError('Cannot confirm a retired sync operation');
      }
      final hash =
          record.after ??
          (throw StateError('Missing synchronized content snapshot'));
      baseline(record.scope); // Validate existing evidence before replacing it.
      final current = _db.select(
        'SELECT sequence FROM content_baselines WHERE scope = ?',
        [record.scope.id],
      );
      if (current.isEmpty ||
          (current.single['sequence'] as int) <= record.sequence) {
        final identity = jsonEncode([
          root,
          record.scope.id,
          record.sequence,
          record.id,
          hash,
        ]);
        _db.execute(
          'INSERT OR REPLACE INTO content_baselines VALUES (?, ?, ?, ?, ?)',
          [
            record.scope.id,
            record.sequence,
            record.id,
            hash,
            _digest(identity),
          ],
        );
      }
      record.payload['confirmed'] = true;
      record.payload['version'] = 2;
      record.payload['completedState'] = 'applied';
      _save(record);
    });
  }

  /// Caller must prove the transfer did not start, or verify a durable terminal
  /// not-applied receipt. This decision survives marker removal and receipt ack.
  void completeNotApplied(String id) {
    final record =
        lookup(id) ?? (throw StateError('Missing sync content candidate'));
    if (record.confirmed) {
      throw StateError('Applied content cannot be rolled back');
    }
    record.payload['version'] = 2;
    record.payload['completedState'] = 'notApplied';
    _save(record);
  }

  void verifyCompleted(DataSyncContentRecord record) {
    if (record.completedState == null) {
      throw StateError('Sync content is unfinished');
    }
    if (record.completedState == DataSyncCommitState.applied) {
      if (baseline(record.scope) == null) {
        throw StateError('Missing confirmed content baseline');
      }
      final current = _db.select(
        'SELECT sequence, operation_id, fingerprint FROM content_baselines WHERE scope = ?',
        [record.scope.id],
      ).single;
      if ((current['sequence'] as int) < record.sequence ||
          (current['sequence'] == record.sequence &&
              (current['operation_id'] != record.id ||
                  current['fingerprint'] != record.after))) {
        throw StateError('Confirmed content baseline disagrees with candidate');
      }
    }
  }

  void acknowledge(String id) {
    _checkOpen();
    lookup(id); // Never discard an unreadable record as successful cleanup.
    _db.execute('DELETE FROM content_operations WHERE id = ?', [id]);
  }

  void _save(DataSyncContentRecord record) {
    _checkOpen();
    final payload = jsonEncode(record.payload);
    _db.execute(
      'UPDATE content_operations SET payload = ?, digest = ? WHERE id = ?',
      [payload, _digest(payload), record.id],
    );
  }

  void close() {
    if (_closed) return;
    _db.dispose();
    _closed = true;
  }
}
