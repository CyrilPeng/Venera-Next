import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

import 'source_mutation_failure.dart';

/// A cleanup receipt proves filesystem state, not successful native release.
class SourceDataResourceReleaseFailure extends SourceMutationFailure {
  SourceDataResourceReleaseFailure(Object error, StackTrace stack, String path)
    : super(
        state: SourceMutationState.recoveryRequired,
        recoveryPath: p.dirname(path),
        failures: [
          (stage: 'close source ownership lock', error: error, stack: stack),
        ],
      );
}

/// Durable ownership of ordinary source-write staging, independent of the
/// source/script transaction. Recovery only removes owned staging; it never
/// replaces a live .data file or infers that an interrupted save succeeded.
class SourceDataJournal {
  SourceDataJournal._(this.root, this.directory, this._db);

  static const directoryName = '.source-data-recovery';
  static final _ids = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _keys = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$');
  static final _held = <String>{};
  static final _gates = <String, Future<void>>{};

  static SourceDataJournal? open(String dataPath, {bool create = true}) {
    final data = Directory(p.normalize(p.absolute(dataPath)));
    if (!data.existsSync() && !create) return null;
    if (create) data.createSync(recursive: true);
    final root = p.normalize(data.resolveSymbolicLinksSync());
    final directory = Directory(p.join(root, directoryName));
    checkPath(root, directory.path, FileSystemEntityType.directory);
    if (!directory.existsSync() && !create) return null;
    directory.createSync();
    final database = p.join(directory.path, 'ownership.sqlite');
    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      checkPath(root, database + suffix, FileSystemEntityType.file);
    }
    final db = openSqliteDatabase(database);
    try {
      db.execute('PRAGMA synchronous = FULL;');
      db.execute('PRAGMA secure_delete = ON;');
      final version = db.select('PRAGMA user_version;').single.values.first;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported source data recovery journal');
      }
      db.execute('''
        CREATE TABLE IF NOT EXISTS writes (
          id TEXT PRIMARY KEY,
          data_root TEXT NOT NULL,
          source_key TEXT NOT NULL,
          contents TEXT NOT NULL,
          digest TEXT NOT NULL
        );
        PRAGMA user_version = 1;
      ''');
      return SourceDataJournal._(root, directory, db);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  final String root;
  final Directory directory;
  final Database _db;

  static Future<void> _closeLock(RandomAccessFile lock) async {
    try {
      await lock.close();
    } catch (error, stack) {
      throw SourceDataResourceReleaseFailure(error, stack, lock.path);
    }
  }

  /// Every existing component below the user-selected root must be an actual
  /// directory/file, not an alias to a different resource. The root itself was
  /// resolved when opened, allowing a deliberately selected data-directory link.
  static void checkPath(String root, String path, FileSystemEntityType kind) {
    final absolute = p.normalize(p.absolute(path));
    if (!p.isWithin(root, absolute)) {
      throw FileSystemException(
        'Source staging escapes its data directory',
        path,
      );
    }
    var current = root;
    final parts = p.split(p.relative(absolute, from: root));
    for (var index = 0; index < parts.length; index++) {
      current = p.join(current, parts[index]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      final expected = index == parts.length - 1
          ? kind
          : FileSystemEntityType.directory;
      if (type != expected) {
        throw FileSystemException('Source staging path changed type', current);
      }
      final resolved = expected == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinksSync()
          : File(current).resolveSymbolicLinksSync();
      if (!p.equals(p.normalize(resolved), current)) {
        throw FileSystemException('Source staging path is aliased', current);
      }
    }
  }

  Future<T> _withGate<T>(Future<T> Function() action) async {
    final file = File(p.join(directory.path, 'access.lock'));
    final previous = _gates[file.path] ?? Future<void>.value();
    final done = Completer<void>();
    _gates[file.path] = done.future;
    try {
      await previous;
      checkPath(root, file.path, FileSystemEntityType.file);
      final lock = await file.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        if (await lock.length() != 0) {
          throw FileSystemException(
            'Source journal gate contains unknown data',
            file.path,
          );
        }
        return await action();
      } finally {
        await _closeLock(lock);
      }
    } finally {
      done.complete();
      if (identical(_gates[file.path], done.future)) _gates.remove(file.path);
    }
  }

  Future<SourceDataWriteRecord> begin(String key, String contents) =>
      _withGate(() async {
        if (!_keys.hasMatch(key)) throw ArgumentError.value(key, 'source key');
        final id = const Uuid().v4();
        final lock = await _acquire(id);
        try {
          _db.execute('INSERT INTO writes VALUES (?, ?, ?, ?, ?)', [
            id,
            root,
            key,
            contents,
            sha256.convert(utf8.encode(contents)).toString(),
          ]);
          return SourceDataWriteRecord._(this, id, key, contents, lock);
        } catch (_) {
          await _release(id, lock, remove: true);
          rethrow;
        }
      });

  Future<RandomAccessFile> _acquire(String id) async {
    final file = File(p.join(directory.path, '$id.lock'));
    checkPath(root, file.path, FileSystemEntityType.file);
    if (!_held.add(file.path)) {
      throw StateError(
        'Source data staging is still owned by a live write: $id',
      );
    }
    RandomAccessFile? lock;
    try {
      lock = await file.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      if (await lock.length() != 0) {
        throw FileSystemException(
          'Source ownership lock contains unknown data',
          file.path,
        );
      }
      return lock;
    } catch (_) {
      try {
        if (lock != null) {
          await _closeLock(lock);
        }
      } finally {
        _held.remove(file.path);
      }
      rethrow;
    }
  }

  Future<void> _release(
    String id,
    RandomAccessFile lock, {
    required bool remove,
  }) async {
    final file = File(p.join(directory.path, '$id.lock'));
    try {
      await _closeLock(lock);
      if (remove) {
        checkPath(root, file.path, FileSystemEntityType.file);
        if (await file.exists()) await file.delete();
      }
    } finally {
      _held.remove(file.path);
    }
  }

  Future<void> recover(
    Future<void> Function(SourceDataWriteRecord) cleanup, {
    SourceDataCleanup? only,
  }) async {
    if (only != null && only.root != root) {
      throw StateError('Source cleanup belongs to another data directory');
    }
    final failures = <SourceMutationError>[];
    final rows = only == null
        ? _db.select('SELECT * FROM writes ORDER BY rowid')
        : _db.select('SELECT * FROM writes WHERE id = ?', [only.id]);
    for (final row in rows) {
      SourceDataWriteRecord? record;
      try {
        final id = row['id'];
        final key = row['source_key'];
        final contents = row['contents'];
        if (id is! String ||
            !_ids.hasMatch(id) ||
            row['data_root'] != root ||
            key is! String ||
            !_keys.hasMatch(key) ||
            contents is! String ||
            row['digest'] != sha256.convert(utf8.encode(contents)).toString() ||
            (only != null &&
                (key != only.key || row['digest'] != only.digest))) {
          throw const FormatException('Invalid source data ownership record');
        }
        final lock = await _withGate(() async {
          if (_db.select('SELECT id FROM writes WHERE id = ?', [id]).isEmpty) {
            return null;
          }
          return _acquire(id);
        });
        if (lock == null) continue;
        record = SourceDataWriteRecord._(this, id, key, contents, lock);
        await record.validateResidue();
        await cleanup(record);
        record.acknowledge();
      } catch (error, stack) {
        failures.add((
          stage: 'recover source staging ${row['id']}',
          error: error,
          stack: stack,
        ));
      } finally {
        if (record != null) {
          try {
            await record.release();
          } catch (error, stack) {
            failures.add((
              stage: 'release source staging ownership',
              error: error,
              stack: stack,
            ));
          }
        }
      }
    }
    // A kill after acknowledging cleanup can leave only the empty lock. Never
    // reclaim another process's active lock, unrecognized names or nonempty files.
    for (final entity in directory.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.endsWith('.lock')) continue;
      final id = name.substring(0, name.length - 5);
      if (only != null && id != only.id) continue;
      if (!_ids.hasMatch(id) ||
          _db.select('SELECT id FROM writes WHERE id = ?', [id]).isNotEmpty) {
        continue;
      }
      try {
        await _withGate(() async {
          if (_db.select('SELECT id FROM writes WHERE id = ?', [
                id,
              ]).isNotEmpty ||
              !await File(entity.path).exists()) {
            return;
          }
          final lock = await _acquire(id);
          await _release(id, lock, remove: true);
        });
      } catch (error, stack) {
        failures.add((
          stage: 'recover source ownership lock $id',
          error: error,
          stack: stack,
        ));
      }
    }
    if (failures.isNotEmpty) {
      throw SourceMutationFailure(
        state: SourceMutationState.recoveryRequired,
        recoveryPath: directory.path,
        failures: failures,
      );
    }
    only?.verifyComplete();
  }

  void close() => _db.dispose();
}

class SourceDataWriteRecord {
  SourceDataWriteRecord._(
    this._journal,
    this.id,
    this.key,
    this.contents,
    this._lock,
  );
  final SourceDataJournal _journal;
  final String id;
  final String key;
  final String contents;
  final RandomAccessFile _lock;
  bool _acknowledged = false;

  SourceDataCleanup get cleanup => SourceDataCleanup._(
    _journal.root,
    id,
    key,
    sha256.convert(utf8.encode(contents)).toString(),
  );

  Directory get directory =>
      Directory(p.join(_journal.root, 'comic_source', '.source-data-$id'));
  File get temporary => File(p.join(directory.path, 'contents'));
  File get target => File(p.join(_journal.root, 'comic_source', '$key.data'));

  void checkPaths() {
    SourceDataJournal.checkPath(
      _journal.root,
      directory.path,
      FileSystemEntityType.directory,
    );
    SourceDataJournal.checkPath(
      _journal.root,
      temporary.path,
      FileSystemEntityType.file,
    );
  }

  Future<void> validateResidue() async {
    checkPaths();
    if (!await temporary.exists()) return;
    final expected = utf8.encode(contents);
    if (await temporary.length() > expected.length) {
      throw FileSystemException(
        'Source staging was changed after interruption',
        temporary.path,
      );
    }
    final actual = await temporary.readAsBytes();
    for (var i = 0; i < actual.length; i++) {
      if (i >= expected.length || actual[i] != expected[i]) {
        throw FileSystemException(
          'Source staging was changed after interruption',
          temporary.path,
        );
      }
    }
  }

  void acknowledge() {
    _journal._db.execute('DELETE FROM writes WHERE id = ?', [id]);
    _acknowledged = true;
  }

  Future<void> release() async {
    var releasing = false;
    try {
      await _journal._withGate(() async {
        releasing = true;
        await _journal._release(id, _lock, remove: _acknowledged);
      });
    } finally {
      // A damaged gate must not strand this instance's descriptor. Keep the
      // ownership file/intent for recovery after its conflict is resolved.
      if (!releasing) {
        await _journal._release(id, _lock, remove: false);
      }
    }
  }
}

/// In-memory proof of the exact intent that failed cleanup. It contains no
/// credentials and remains valid after the original journal connection closes.
class SourceDataCleanup {
  SourceDataCleanup._(this.root, this.id, this.key, this.digest);
  final String root;
  final String id;
  final String key;
  final String digest;

  void verifyRoot() {
    final data = Directory(root);
    if (!data.existsSync() ||
        !p.equals(p.normalize(data.resolveSymbolicLinksSync()), root)) {
      throw FileSystemException('Source cleanup directory changed', root);
    }
  }

  void verifyComplete() {
    verifyRoot();
    for (final path in [
      p.join(root, 'comic_source', '.source-data-$id'),
      p.join(root, SourceDataJournal.directoryName, '$id.lock'),
    ]) {
      // Validate parents even when a missing journal no longer describes the
      // residue. Missing intent alone is never evidence of completed cleanup.
      SourceDataJournal.checkPath(
        root,
        path,
        path.endsWith('.lock')
            ? FileSystemEntityType.file
            : FileSystemEntityType.directory,
      );
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Source cleanup remains incomplete', path);
      }
    }
  }
}
