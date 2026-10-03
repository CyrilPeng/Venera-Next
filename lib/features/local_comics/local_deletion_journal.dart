import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

/// Durable ownership of directories moved out of the live library before a
/// database deletion. Only committed quarantine paths may be removed on retry.
class LocalDeletionJournal {
  LocalDeletionJournal(this.db, {required this.exists});

  final Database db;
  final Future<bool> Function(String path) exists;

  void initialize() =>
      db.execute('''CREATE TABLE IF NOT EXISTS local_deletion_journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    original_path TEXT NOT NULL,
    quarantine_path TEXT NOT NULL,
    committed INTEGER NOT NULL DEFAULT 0
  );''');

  Future<void> recover() async {
    for (final row in db.select(
      'SELECT * FROM local_deletion_journal ORDER BY id DESC',
    )) {
      await _recoverRow(row);
    }
  }

  Future<void> _recoverRow(Row row) async {
    final id = row['id'] as int;
    final original = row['original_path'] as String;
    final quarantine = row['quarantine_path'] as String;
    // A journal is local state, but never allow malformed entries to designate
    // a parent, the original path or a different directory for recursive I/O.
    if (!p.equals(p.dirname(original), p.dirname(quarantine)) ||
        p.equals(original, quarantine) ||
        !p.basename(quarantine).startsWith('.venera-delete-')) {
      throw StateError('Invalid local deletion journal path');
    }
    final staged = await exists(quarantine);
    if (row['committed'] == 1) {
      if (staged) await Directory(quarantine).delete(recursive: true);
    } else if (staged) {
      if (await exists(original)) {
        throw FileSystemException(
          'Cannot restore deletion: original path is occupied',
          original,
        );
      }
      await Directory(quarantine).rename(original);
    } else if (!await exists(original)) {
      throw FileSystemException(
        'Cannot restore deletion: both paths are missing',
        original,
      );
    }
    db.execute('DELETE FROM local_deletion_journal WHERE id = ?', [id]);
  }

  /// The callback must mark this journal in the same SQLite transaction that
  /// removes records. Publication errors after commit must not restore files.
  Future<void> run(
    List<Directory> directories,
    Future<void> Function(void Function() markCommitted) commit,
  ) async {
    await recover();
    final ids = <int>[];
    try {
      final roots = <String>[];
      final candidates =
          directories
              .map((directory) => p.normalize(p.absolute(directory.path)))
              .toSet()
              .toList()
            ..sort((a, b) => a.length.compareTo(b.length));
      for (final original in candidates) {
        if (roots.any(
          (root) => p.equals(root, original) || p.isWithin(root, original),
        )) {
          continue;
        }
        if (!await exists(original)) continue;
        roots.add(original);
        // Allocate an identifier durably before moving any bytes. An existing
        // quarantine is never overwritten, even after restoring an old DB.
        late int id;
        late String quarantine;
        runSqliteTransaction(db, () {
          db.execute(
            'INSERT INTO local_deletion_journal(original_path, quarantine_path) VALUES (?, ?)',
            [original, ''],
          );
          id = db.lastInsertRowId;
          quarantine = p.join(
            p.dirname(original),
            '.venera-delete-$id-${DateTime.now().microsecondsSinceEpoch}',
          );
          db.execute(
            'UPDATE local_deletion_journal SET quarantine_path = ? WHERE id = ?',
            [quarantine, id],
          );
        });
        ids.add(id);
        if (await exists(quarantine)) {
          // This path is not owned by us. Forget this unstarted entry so a
          // recovery attempt cannot restore or delete someone else's directory.
          db.execute('DELETE FROM local_deletion_journal WHERE id = ?', [id]);
          throw FileSystemException(
            'Deletion quarantine already exists',
            quarantine,
          );
        }
        await Directory(original).rename(quarantine);
      }
      await commit(() {
        if (db.autocommit) {
          throw StateError('Deletion journal requires an active transaction');
        }
        for (final id in ids) {
          db.execute(
            'UPDATE local_deletion_journal SET committed = 1 WHERE id = ?',
            [id],
          );
        }
      });
    } catch (error, stack) {
      try {
        await recover();
      } catch (recoveryError, recoveryStack) {
        throw LocalDeletionRecoveryFailure(
          error,
          stack,
          recoveryError,
          recoveryStack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    await recover();
  }
}

class LocalDeletionRecoveryFailure implements Exception {
  const LocalDeletionRecoveryFailure(
    this.operation,
    this.operationStack,
    this.recovery,
    this.recoveryStack,
  );
  final Object operation;
  final StackTrace operationStack;
  final Object recovery;
  final StackTrace recoveryStack;
  @override
  String toString() =>
      'Local deletion failed: $operation; recovery failed: $recovery';
}
