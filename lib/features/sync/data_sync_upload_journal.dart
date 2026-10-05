import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

import 'data_sync_commit.dart';

String dataSyncEndpointFingerprint(List<String> connection) {
  if (connection.length != 3) {
    throw ArgumentError('Expected URL and credentials');
  }
  return crypto.sha256.convert(utf8.encode(jsonEncode(connection))).toString();
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _hash = RegExp(r'^[0-9a-f]{64}$');
const _phases = {
  'preparing',
  'prepared',
  'putPending',
  'confirmed',
  'finalizing',
  'finished',
  'notApplied',
};

/// Durable identity of an archive selected by the pre-upload retention policy.
class DataSyncRetentionIdentity {
  const DataSyncRetentionIdentity({
    required this.name,
    required this.sha256,
    required this.length,
    required this.strongEtag,
  });
  final String name;
  final String sha256;
  final int length;
  final String? strongEtag;

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'length': length,
    'etag': strongEtag,
  };

  static DataSyncRetentionIdentity fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_keys(value, {'name', 'sha256', 'length', 'etag'}) ||
        !_archiveName(value['name']) ||
        !_validHash(value['sha256']) ||
        value['length'] is! int ||
        (value['length'] as int) < 0 ||
        (value['etag'] != null && !_strongEtag(value['etag']))) {
      throw const FormatException('Invalid upload retention identity');
    }
    return DataSyncRetentionIdentity(
      name: value['name'] as String,
      sha256: value['sha256'] as String,
      length: value['length'] as int,
      strongEtag: value['etag'] as String?,
    );
  }
}

class DataSyncUploadRecord {
  DataSyncUploadRecord({
    required this.operationId,
    required this.endpointFingerprint,
    this.phase = 'preparing',
    this.remoteName,
    this.sha256,
    this.length,
    this.version,
    this.committedAt,
    this.retentionPlanned = false,
    List<DataSyncRetentionIdentity> retention = const [],
    this.timeSaved = false,
    this.sourceCleaned = false,
    this.sourceOwned = false,
  }) : retention = List.of(retention);

  final String operationId;
  final String endpointFingerprint;
  String phase;
  String? remoteName;
  String? sha256;
  int? length;
  int? version;
  int? committedAt;
  bool retentionPlanned;
  final List<DataSyncRetentionIdentity> retention;
  bool timeSaved;
  bool sourceCleaned;
  bool sourceOwned;

  bool get isTerminal => phase == 'finished' || phase == 'notApplied';
  DataSyncCommitState get commitState => switch (phase) {
    'confirmed' || 'finalizing' || 'finished' => DataSyncCommitState.applied,
    'putPending' => DataSyncCommitState.recoveryRequired,
    _ => DataSyncCommitState.notApplied,
  };

  Map<String, Object?> toJson() => {
    'id': operationId,
    'endpoint': endpointFingerprint,
    'phase': phase,
    'name': remoteName,
    'hash': sha256,
    'length': length,
    'version': version,
    'committedAt': committedAt,
    'retentionPlanned': retentionPlanned,
    'retention': retention.map((entry) => entry.toJson()).toList(),
    'timeSaved': timeSaved,
    'sourceCleaned': sourceCleaned,
    'sourceOwned': sourceOwned,
  };

  static DataSyncUploadRecord fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_keys(value, {
          'id',
          'endpoint',
          'phase',
          'name',
          'hash',
          'length',
          'version',
          'committedAt',
          'retentionPlanned',
          'retention',
          'timeSaved',
          'sourceCleaned',
          'sourceOwned',
        }) ||
        value['id'] is! String ||
        !_uuid.hasMatch(value['id'] as String) ||
        !_validHash(value['endpoint']) ||
        !_phases.contains(value['phase']) ||
        value['retentionPlanned'] is! bool ||
        value['retention'] is! List ||
        value['timeSaved'] is! bool ||
        value['sourceCleaned'] is! bool ||
        value['sourceOwned'] is! bool) {
      throw const FormatException('Invalid upload journal record');
    }
    final phase = value['phase'] as String;
    final unprepared = phase == 'preparing' || phase == 'notApplied';
    final confirmed = {'confirmed', 'finalizing', 'finished'}.contains(phase);
    if (unprepared) {
      if ([
            'name',
            'hash',
            'length',
            'version',
            'committedAt',
          ].any((key) => value[key] != null) ||
          value['retentionPlanned'] != false ||
          (value['retention'] as List).isNotEmpty ||
          value['timeSaved'] != false) {
        throw const FormatException('Invalid unprepared upload record');
      }
    } else {
      if (value['sourceOwned'] != true ||
          !_archiveName(value['name']) ||
          !_validHash(value['hash']) ||
          value['length'] is! int ||
          (value['length'] as int) < 0 ||
          value['version'] is! int ||
          (value['version'] as int) < 0 ||
          !(value['name'] as String).endsWith(
            '-${value['version']}-${value['id']}.venera',
          ) ||
          !RegExp(r'^\d+-').hasMatch(value['name'] as String)) {
        throw const FormatException('Invalid upload snapshot metadata');
      }
      if (confirmed
          ? !isValidDataSyncCommitTime(value['committedAt'])
          : value['committedAt'] != null) {
        throw const FormatException('Invalid upload commit time');
      }
      if ((phase == 'putPending' || confirmed) &&
          value['retentionPlanned'] != true) {
        throw const FormatException('Upload intent has no retention plan');
      }
      if (!confirmed &&
          (value['timeSaved'] == true || value['sourceCleaned'] == true)) {
        throw const FormatException('Unconfirmed upload was cleaned');
      }
    }
    final retention = (value['retention'] as List)
        .map(DataSyncRetentionIdentity.fromJson)
        .toList();
    if (retention.map((entry) => entry.name).toSet().length !=
            retention.length ||
        retention.any((entry) => entry.name == value['name']) ||
        (value['retentionPlanned'] == false && retention.isNotEmpty) ||
        (phase == 'finished' &&
            (retention.isNotEmpty ||
                value['timeSaved'] != true ||
                value['sourceCleaned'] != true)) ||
        (phase == 'notApplied' && value['sourceCleaned'] != true)) {
      throw const FormatException('Invalid upload finalization state');
    }
    return DataSyncUploadRecord(
      operationId: value['id'] as String,
      endpointFingerprint: value['endpoint'] as String,
      phase: phase,
      remoteName: value['name'] as String?,
      sha256: value['hash'] as String?,
      length: value['length'] as int?,
      version: value['version'] as int?,
      committedAt: value['committedAt'] as int?,
      retentionPlanned: value['retentionPlanned'] as bool,
      retention: retention,
      timeSaved: value['timeSaved'] as bool,
      sourceCleaned: value['sourceCleaned'] as bool,
      sourceOwned: value['sourceOwned'] as bool,
    );
  }
}

/// Independent DELETE/FULL journal. A receipt outlives its owned snapshot and
/// is acknowledged only after the controller has durably cleared its marker.
class DataSyncUploadJournal {
  DataSyncUploadJournal._(this.dataPath, this._db);

  factory DataSyncUploadJournal.open(String dataPath) {
    final root = Directory(p.normalize(p.absolute(dataPath)));
    root.createSync(recursive: true);
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(p.normalize(root.resolveSymbolicLinksSync()), root.path)) {
      throw const FormatException('Upload data path contains a link');
    }
    final path = p.join(root.path, '.data-sync-upload.sqlite');
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      _checkPath(root.path, path + suffix);
    }
    final db = openSqliteDatabase(path);
    try {
      db.execute('PRAGMA synchronous = FULL;');
      final version = db.select('PRAGMA user_version;').single.values.first;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported upload journal schema');
      }
      db.execute('''CREATE TABLE IF NOT EXISTS upload_operations (
        id TEXT PRIMARY KEY NOT NULL, record TEXT NOT NULL
      );''');
      db.execute('PRAGMA user_version = 1;');
      final result = DataSyncUploadJournal._(root.path, db);
      result
          .records; // Validate all persisted evidence before accepting writes.
      return result;
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  final String dataPath;
  final Database _db;
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Upload journal is closed');
  }

  List<DataSyncUploadRecord> get records {
    _checkOpen();
    return _db
        .select('SELECT id, record FROM upload_operations ORDER BY rowid')
        .map(_read)
        .toList(growable: false);
  }

  DataSyncUploadRecord _read(Row row) {
    final record = DataSyncUploadRecord.fromJson(
      jsonDecode(row['record'] as String),
    );
    if (record.operationId != row['id']) {
      throw const FormatException('Upload operation identity mismatch');
    }
    return record;
  }

  DataSyncUploadRecord? lookup(String operationId) {
    _checkOpen();
    _checkId(operationId);
    final rows = _db.select(
      'SELECT id, record FROM upload_operations WHERE id = ?',
      [operationId],
    );
    return rows.isEmpty ? null : _read(rows.single);
  }

  void save(DataSyncUploadRecord record) {
    _checkOpen();
    DataSyncUploadRecord.fromJson(record.toJson());
    _db.execute(
      '''INSERT INTO upload_operations(id, record) VALUES (?, ?)
      ON CONFLICT(id) DO UPDATE SET record = excluded.record''',
      [record.operationId, jsonEncode(record.toJson())],
    );
  }

  Directory operationDirectory(String operationId) {
    _checkOpen();
    _checkId(operationId);
    final path = p.join(dataPath, '.data-sync-upload-$operationId');
    _checkPath(dataPath, path);
    return Directory(path);
  }

  File snapshotFile(String operationId) {
    final directory = operationDirectory(operationId);
    final path = p.join(directory.path, 'snapshot.venera');
    _checkPath(dataPath, path);
    return File(path);
  }

  Future<void> cleanup(String operationId) async {
    final record = lookup(operationId);
    if (record == null || !record.sourceOwned || record.sourceCleaned) return;
    if ({'prepared', 'putPending'}.contains(record.phase)) {
      throw StateError('Unconfirmed upload snapshot must be retained');
    }
    final directory = operationDirectory(operationId);
    if (!directory.existsSync()) return;
    final snapshot = snapshotFile(operationId);
    final staging = Directory(p.join(directory.path, 'export-staging'));
    for (final entry in directory.listSync(followLinks: false)) {
      _checkPath(dataPath, entry.path);
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      if (p.equals(entry.path, staging.path) &&
          type == FileSystemEntityType.directory) {
        _checkTree(dataPath, staging);
      } else if (!p.equals(entry.path, snapshot.path) ||
          type != FileSystemEntityType.file) {
        throw const FormatException(
          'Unexpected file in owned upload directory',
        );
      }
    }
    if (snapshot.existsSync()) await snapshot.delete();
    if (staging.existsSync()) {
      _checkTree(dataPath, staging);
      await staging.delete(recursive: true);
    }
    await directory.delete();
  }

  Future<void> acknowledge(String operationId) async {
    final record = lookup(operationId);
    if (record == null) return;
    if (!record.isTerminal) throw StateError('Upload recovery is not complete');
    await cleanup(operationId);
    _db.execute('DELETE FROM upload_operations WHERE id = ?', [operationId]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }
}

void _checkId(String id) {
  if (!_uuid.hasMatch(id)) {
    throw const FormatException('Invalid upload operation UUID');
  }
}

bool _keys(Map<String, dynamic> value, Set<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);
bool _validHash(Object? value) => value is String && _hash.hasMatch(value);
bool _archiveName(Object? value) =>
    value is String &&
    value.endsWith('.venera') &&
    value != '.venera' &&
    !value.contains(RegExp(r'[/\\\x00-\x1f]')) &&
    value != '..' &&
    value != '.';
bool _strongEtag(Object? value) =>
    value is String && RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);

void _checkPath(String root, String path) {
  if (!p.isWithin(root, path)) {
    throw const FormatException('Upload path escaped data directory');
  }
  var current = path;
  while (!p.equals(current, root)) {
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            !p.equals(
              p.normalize(File(current).resolveSymbolicLinksSync()),
              current,
            ))) {
      throw const FormatException('Upload path contains a link');
    }
    current = p.dirname(current);
  }
}

void _checkTree(String root, Directory directory) {
  _checkPath(root, directory.path);
  for (final entry in directory.listSync(followLinks: false)) {
    _checkPath(root, entry.path);
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _checkTree(root, Directory(entry.path));
    } else if (type != FileSystemEntityType.file) {
      throw const FormatException('Invalid upload staging entry');
    }
  }
}
