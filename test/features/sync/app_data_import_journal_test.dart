import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';

void main() {
  late Directory root;
  late Directory data;
  late Directory incoming;
  late AppDataImportJournal journal;
  late AppDataImportObserver? observer;

  File live(String name) => File(p.join(data.path, name));
  File source(String name, [String content = 'incoming']) =>
      File(p.join(incoming.path, name))..writeAsStringSync(content);

  void editJournal(String sql, [List<Object?> parameters = const []]) {
    final db = sqlite3.open(p.join(data.path, '.app-data-import.sqlite'));
    try {
      db.execute(sql, parameters);
    } finally {
      db.dispose();
    }
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('import-journal-unit-');
    data = Directory(p.join(root.path, 'data'))..createSync();
    incoming = Directory(p.join(root.path, 'incoming'))..createSync();
    for (final name in ['appdata.json', 'syncdata.json']) {
      for (final suffix in ['', '.bak', '.tmp']) {
        live(name + suffix).writeAsStringSync('original $name$suffix');
      }
    }
    live('history.db').writeAsStringSync('original history');
    observer = null;
    journal = AppDataImportJournal.open(
      data.path,
      observer: (event) => observer?.call(event),
    );
  });

  tearDown(() {
    journal.close();
    root.deleteSync(recursive: true);
  });

  test('prepares immutable images and repeats rollback until terminal', () async {
    final transaction = await journal.prepare(resources: {'history.db'});
    expect(transaction.state, DataSyncCommitState.notApplied);
    await transaction.replaceFile('history.db', source('history.db'));
    await transaction.markChanging('appdata.json');
    live('appdata.json').writeAsStringSync('changed primary');
    live('appdata.json.bak').writeAsStringSync('changed backup');
    live('appdata.json.tmp').deleteSync();
    expect(transaction.state, DataSyncCommitState.recoveryRequired);
    expect(await transaction.restore(), isEmpty);
    expect(transaction.unrestoredResources, isEmpty);
    expect(live('history.db').readAsStringSync(), 'original history');
    for (final suffix in ['', '.bak', '.tmp']) {
      expect(
        live('appdata.json$suffix').readAsStringSync(),
        'original appdata.json$suffix',
      );
    }
    // Reopening an application store may repair data before a later save fails.
    live('history.db').writeAsStringSync('reopen repair');
    live('appdata.json').writeAsStringSync('reopen settings');
    expect(await transaction.restore(), isEmpty);
    expect(live('history.db').readAsStringSync(), 'original history');
    expect(live('appdata.json').readAsStringSync(), 'original appdata.json');
    await transaction.markRolledBack();
    expect(transaction.state, DataSyncCommitState.notApplied);
    await transaction.cleanup();
    expect(journal.receipts, isEmpty);
  });

  test(
    'DB sidecars retire before install and restore with their old main',
    () async {
      for (final suffix in ['-journal', '-wal', '-shm']) {
        live('history.db$suffix').writeAsStringSync('original $suffix');
      }
      final transaction = await journal.prepare(resources: {'history.db'});
      var sawRemoval = false;
      observer = (event) {
        if (event.phase == 'targetRemoved' && event.resource == 'history.db') {
          sawRemoval = true;
          for (final suffix in ['-journal', '-wal', '-shm']) {
            expect(live('history.db$suffix').existsSync(), isFalse);
          }
        }
      };
      await transaction.replaceFile('history.db', source('history.db'));
      expect(sawRemoval, isTrue);
      live('history.db-journal').writeAsStringSync('new epoch journal');
      expect(await transaction.restore(skip: {'history.db'}), isEmpty);
      expect(transaction.unrestoredResources, contains('history.db'));
      expect(live('history.db').readAsStringSync(), 'incoming');
      await expectLater(transaction.markRolledBack(), throwsStateError);
      expect(await transaction.restore(), isEmpty);
      expect(live('history.db').readAsStringSync(), 'original history');
      for (final suffix in ['-journal', '-wal', '-shm']) {
        expect(
          live('history.db$suffix').readAsStringSync(),
          'original $suffix',
        );
      }
      await transaction.markRolledBack();
    },
  );

  for (final damage in ['missing', 'modified']) {
    test('a $damage backup cannot overwrite the live target', () async {
      final transaction = await journal.prepare(resources: {'history.db'});
      await transaction.replaceFile('history.db', source('history.db'));
      await transaction.markChanging('appdata.json');
      live('appdata.json').writeAsStringSync('changed');
      final backup = File(
        p.join(transaction.directoryPath, 'before', 'history.db'),
      );
      if (damage == 'missing') {
        backup.deleteSync();
      } else {
        backup.writeAsStringSync('damaged');
      }
      final failures = await transaction.restore();
      expect(failures, hasLength(1));
      expect(failures.single.error, isA<FileSystemException>());
      expect(transaction.unrestoredResources, contains('history.db'));
      expect(live('history.db').readAsStringSync(), 'incoming');
      expect(live('appdata.json').readAsStringSync(), 'original appdata.json');
      backup.writeAsStringSync('original history');
      expect(await transaction.restore(), isEmpty);
      await transaction.markRolledBack();
    });
  }

  for (final name in ['appdata.json.tmp', 'history.db-wal', 'history.db']) {
    test('a missing journal resource row rejects recovery: $name', () async {
      final transaction = await journal.prepare(resources: {'history.db'});
      await transaction.replaceFile('history.db', source('history.db'));
      editJournal(
        'DELETE FROM import_resources WHERE operation_id=? AND name=?',
        [transaction.id, name],
      );
      await expectLater(transaction.restore(), throwsFormatException);
      await expectLater(transaction.markApplied(10), throwsFormatException);
      expect(live('history.db').readAsStringSync(), 'incoming');
      expect(Directory(transaction.directoryPath).existsSync(), isTrue);
    });
  }

  test(
    'altered valid-looking resource fingerprints fail manifest validation',
    () async {
      final transaction = await journal.prepare(resources: {'history.db'});
      await transaction.replaceFile('history.db', source('history.db'));
      editJournal(
        'UPDATE import_resources SET before_hash=? WHERE operation_id=? AND name=?',
        ['a' * 64, transaction.id, 'history.db'],
      );
      await expectLater(transaction.restore(), throwsFormatException);
      expect(live('history.db').readAsStringSync(), 'incoming');
    },
  );

  test('unresolved operations reject a second preparation', () async {
    final transaction = await journal.prepare(resources: {'history.db'});
    final failure = isA<DataSyncImportFailure>()
        .having(
          (value) => value.commitState,
          'state',
          DataSyncCommitState.recoveryRequired,
        )
        .having(
          (value) => value.recoveryPath,
          'path',
          transaction.directoryPath,
        )
        .having(
          (value) => value.failures.single.stage,
          'stage',
          'pending import recovery',
        );
    expect(journal.checkReadyForImport, throwsA(failure));
    await expectLater(journal.prepare(resources: {}), throwsA(failure));
    expect(live('history.db').readAsStringSync(), 'original history');
    expect(await transaction.restore(), isEmpty);
    await transaction.markRolledBack();
    final next = await journal.prepare(resources: {});
    expect(next.id, isNot(transaction.id));
    expect(await next.restore(), isEmpty);
    await next.markRolledBack();
  });

  test(
    'invalid persisted phase rejects admission without touching live data',
    () async {
      final transaction = await journal.prepare(resources: {'history.db'});
      editJournal('UPDATE import_operations SET phase=? WHERE id=?', [
        'invalid',
        transaction.id,
      ]);
      final failure = isA<DataSyncImportFailure>()
          .having(
            (value) => value.commitState,
            'state',
            DataSyncCommitState.recoveryRequired,
          )
          .having(
            (value) => value.recoveryPath,
            'path',
            transaction.directoryPath,
          )
          .having((value) => value.cause, 'cause', isA<FormatException>());
      expect(journal.checkReadyForImport, throwsA(failure));
      await expectLater(journal.prepare(resources: {}), throwsA(failure));
      expect(live('history.db').readAsStringSync(), 'original history');
    },
  );

  test('commit time validation preserves valid DateTime boundaries', () async {
    final transaction = await journal.prepare(
      resources: {},
      syncOperationId: 'time-boundary',
    );
    for (final time in [-1, 8640000000000001]) {
      await expectLater(transaction.markApplied(time), throwsArgumentError);
      expect(transaction.state, DataSyncCommitState.notApplied);
    }
    await transaction.markApplied(8640000000000000);
    expect(journal.receipts.single.committedAt, 8640000000000000);
    editJournal('UPDATE import_operations SET committed_at=? WHERE id=?', [
      -1,
      transaction.id,
    ]);
    expect(() => journal.receipts, throwsFormatException);
  });

  test(
    'terminal cleanup failure permits a later import and old cleanup is isolated',
    () async {
      final first = await journal.prepare(resources: {'history.db'});
      await first.replaceFile('history.db', source('history.db', 'first'));
      await first.markApplied(10);
      observer = (event) {
        if (event.id == first.id && event.phase == 'cleanupResource') {
          throw const FileSystemException('held old cleanup');
        }
      };
      await expectLater(first.cleanup(), throwsA(isA<FileSystemException>()));
      final second = await journal.prepare(resources: {'history.db'});
      await second.replaceFile('history.db', source('second.db', 'second'));
      await second.markApplied(20);
      await second.cleanup();
      observer = null;
      journal.close();
      journal = AppDataImportJournal.open(data.path);
      await journal.cleanup(first.id);
      await journal.cleanup(first.id);
      expect(live('history.db').readAsStringSync(), 'second');
      expect(journal.receipts, isEmpty);
    },
  );

  test(
    'sync receipt retains immutable time until idempotent acknowledgement',
    () async {
      final transaction = await journal.prepare(
        resources: {},
        syncOperationId: 'sync-1',
      );
      await transaction.markApplied(123);
      await transaction.markApplied(123);
      await expectLater(transaction.markApplied(124), throwsStateError);
      await transaction.cleanup();
      expect(Directory(transaction.directoryPath).existsSync(), isFalse);
      expect(journal.receipts.single.syncOperationId, 'sync-1');
      expect(journal.receipts.single.committedAt, 123);
      expect((await journal.recoverPending()).single.committedAt, 123);
      await journal.acknowledge(transaction.id);
      await journal.acknowledge(transaction.id);
      expect(journal.receipts, isEmpty);
    },
  );

  test('observer failure after commit cannot restore old files', () async {
    final transaction = await journal.prepare(resources: {'history.db'});
    await transaction.replaceFile('history.db', source('history.db'));
    observer = (event) {
      if (event.phase == 'applied') throw StateError('late observer');
    };
    await expectLater(transaction.markApplied(10), throwsStateError);
    expect(transaction.state, DataSyncCommitState.applied);
    await expectLater(transaction.restore(), throwsStateError);
    observer = null;
    await journal.recoverPending();
    expect(live('history.db').readAsStringSync(), 'incoming');
  });

  test('failed preparation is terminal and does not block retry', () async {
    observer = (event) {
      if (event.phase == 'backedUp' || event.phase == 'cleanupResource') {
        throw const FileSystemException('injected preparation failure');
      }
    };
    await expectLater(
      journal.prepare(resources: {'history.db'}),
      throwsA(
        isA<DataSyncImportFailure>().having(
          (failure) => failure.failures.length,
          'operation and cleanup failures',
          2,
        ),
      ),
    );
    expect(live('history.db').readAsStringSync(), 'original history');
    observer = null;
    final transaction = await journal.prepare(resources: {});
    expect(transaction.state, DataSyncCommitState.notApplied);
  });

  test(
    'a changed live file after prepare is preserved instead of overwritten',
    () async {
      final transaction = await journal.prepare(resources: {'history.db'});
      live('history.db').writeAsStringSync('new local data');
      await expectLater(
        transaction.replaceFile('history.db', source('history.db')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await transaction.restore(), isEmpty);
      expect(live('history.db').readAsStringSync(), 'new local data');
      await transaction.markRolledBack();
    },
  );

  test(
    'unrelated data directories are not traversed during install or restore',
    () async {
      final unrelated = Directory(p.join(data.path, 'unrelated'))..createSync();
      File(p.join(unrelated.path, 'sentinel')).writeAsStringSync('untouched');
      final transaction = await journal.prepare(resources: {'history.db'});
      await IOOverrides.runWithIOOverrides(() async {
        await transaction.replaceFile('history.db', source('history.db'));
        expect(await transaction.restore(), isEmpty);
        await transaction.markRolledBack();
        await transaction.cleanup();
      }, _NoUnrelatedListing(unrelated.path));
      expect(
        File(p.join(unrelated.path, 'sentinel')).readAsStringSync(),
        'untouched',
      );
    },
  );

  test(
    'rejects unknown resource paths before allocating an operation',
    () async {
      await expectLater(
        journal.prepare(resources: {'../outside'}),
        throwsArgumentError,
      );
      expect(journal.receipts, isEmpty);
      final db = sqlite3.open(p.join(data.path, '.app-data-import.sqlite'));
      try {
        expect(db.select('SELECT * FROM import_operations'), isEmpty);
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'rejects a source directory junction without touching its target',
    () async {
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      final sentinel = File(p.join(outside.path, 'sentinel'))
        ..writeAsStringSync('safe');
      final alias = p.join(data.path, 'comic_source');
      if (Platform.isWindows) {
        final created = await Process.run('cmd.exe', [
          '/c',
          'mklink',
          '/J',
          alias,
          outside.path,
        ]);
        expect(created.exitCode, 0, reason: created.stderr.toString());
      } else {
        Link(alias).createSync(outside.path);
      }
      try {
        await expectLater(
          journal.prepare(resources: {'comic_source'}),
          throwsA(isA<FileSystemException>()),
        );
        expect(sentinel.readAsStringSync(), 'safe');
      } finally {
        if (Platform.isWindows) {
          Directory(alias).deleteSync();
        } else {
          Link(alias).deleteSync();
        }
      }
    },
  );
}

final class _NoUnrelatedListing extends IOOverrides {
  _NoUnrelatedListing(this.unrelated);
  final String unrelated;
  @override
  Directory createDirectory(String path) =>
      _GuardDirectory(super.createDirectory(path), p.equals(path, unrelated));
}

class _GuardDirectory implements Directory {
  _GuardDirectory(this.raw, this.forbidden);
  final Directory raw;
  final bool forbidden;
  @override
  String get path => raw.path;
  @override
  String resolveSymbolicLinksSync() => raw.resolveSymbolicLinksSync();
  @override
  Directory createSync({bool recursive = false}) {
    raw.createSync(recursive: recursive);
    return this;
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    if (forbidden) throw StateError('Unrelated data was traversed');
    return raw.listSync(recursive: recursive, followLinks: followLinks);
  }

  @override
  Directory renameSync(String newPath) => raw.renameSync(newPath);
  @override
  Future<Directory> delete({bool recursive = false}) async {
    await raw.delete(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      raw.deleteSync(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
