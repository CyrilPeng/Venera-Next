import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_remote_port.dart';
import 'package:venera_next/features/sync/data_sync_upload_executor.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';
import 'package:venera_next/network/request_scope.dart';

const _id = '4a112222-3333-4444-8555-666666666666';
final _date = DateTime.utc(2026, 10, 5, 12);
final _day = _date.millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.dispose());

  test(
    'missing-journal recovery creates a receipt without touching foreign files',
    () async {
      final directory = f.journal.operationDirectory(_id)..createSync();
      final foreign = File(p.join(directory.path, 'snapshot.venera'))
        ..writeAsStringSync('foreign');
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.notApplied,
      );
      expect(f.exports, 0);
      expect(f.opens, 0);
      expect(foreign.readAsStringSync(), 'foreign');
      expect(f.journal.lookup(_id)!.isTerminal, isTrue);
      await f.journal.acknowledge(_id);
      await f.journal.acknowledge(_id);
      expect(foreign.existsSync(), isTrue);
    },
  );

  test(
    'preparing failure is not applied and retry never exports again',
    () async {
      f.prepareError = StateError('version write failed');
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.commitState, DataSyncCommitState.notApplied);
      expect(error.failures.single.error, same(f.prepareError));
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.notApplied,
      );
      expect(f.exports, 0);
      expect(f.opens, 0);
    },
  );

  test(
    'preparation does not take over a pre-existing UUID directory',
    () async {
      final directory = f.journal.operationDirectory(_id)..createSync();
      final foreign = File(p.join(directory.path, 'snapshot.venera'))
        ..writeAsStringSync('foreign');
      await _failure(f.executor().upload(_id, f.scope));
      expect(foreign.readAsStringSync(), 'foreign');
      expect(f.remote.puts, 0);
      expect(f.journal.lookup(_id)!.sourceOwned, isFalse);
    },
  );

  test('prepared SQLite write failure cannot authorize a PUT', () async {
    f.blockPhase('prepared');
    final error = await _failure(f.executor().upload(_id, f.scope));
    expect(error.failures.single.error, isA<SqliteException>());
    expect(error.commitState, DataSyncCommitState.notApplied);
    expect(f.journal.lookup(_id)!.phase, 'notApplied');
    expect(f.journal.lookup(_id)!.remoteName, isNull);
    expect(f.journal.lookup(_id)!.sha256, isNull);
    expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
    expect(f.opens, 0);
    expect(f.remote.puts, 0);

    f.unblockPhase();
    f.reopen();
    expect(
      await f.executor().recover(_id, f.scope),
      DataSyncCommitState.notApplied,
    );
    expect(f.remote.puts, 0);
    expect(f.exports, 1);
    expect(f.versions, 1);
  });

  test(
    'putPending SQLite write failure preserves prepared bytes without PUT',
    () async {
      f.blockPhase('putPending');
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.failures.single.error, isA<SqliteException>());
      expect(f.journal.lookup(_id)!.phase, 'prepared');
      expect(f.journal.lookup(_id)!.committedAt, isNull);
      expect(f.journal.snapshotFile(_id).readAsBytesSync(), [1, 2, 3]);
      expect(f.remote.puts, 0);

      f.unblockPhase();
      f.reopen();
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.applied,
      );
      expect(f.remote.puts, 1);
      expect(f.exports, 1);
      expect(f.versions, 1);
      expect(f.journal.lookup(_id)!.phase, 'finished');
    },
  );

  test(
    'confirmed SQLite write failure recovers by GET without a second PUT',
    () async {
      f.blockPhase('confirmed');
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.failures.single.error, isA<SqliteException>());
      expect(error.commitState, DataSyncCommitState.recoveryRequired);
      final pending = f.journal.lookup(_id)!;
      expect(pending.phase, 'putPending');
      expect(pending.committedAt, isNull);
      expect(f.journal.snapshotFile(_id).readAsBytesSync(), [1, 2, 3]);
      expect(f.remote.files[pending.remoteName], [1, 2, 3]);
      expect(f.remote.puts, 1);
      expect(f.times, isEmpty);

      f.unblockPhase();
      f.reopen();
      f.remote.probed.clear();
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.applied,
      );
      expect(f.remote.probed, [pending.remoteName]);
      expect(f.remote.puts, 1);
      expect(f.exports, 1);
      expect(f.versions, 1);
      expect(f.times, [_date.millisecondsSinceEpoch]);
      expect(f.journal.lookup(_id)!.phase, 'finished');
      expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
    },
  );

  test('retention preserves global oldest and first today policy', () async {
    for (var day = 1; day <= 9; day++) {
      f.remote.files['$day-1-other-device.venera'] = [day];
    }
    f.remote.files['$_day-2-other-device.venera'] = [20];
    f.remote.files['$_day-10-my-device.venera'] = [21];
    expect(
      await f.executor().upload(_id, f.scope),
      DataSyncCommitState.applied,
    );
    expect(f.remote.removed, {
      '1-1-other-device.venera',
      '$_day-2-other-device.venera',
    });
    expect(f.remote.files, contains('$_day-10-my-device.venera'));
    expect(f.remote.puts, 1);
    expect(f.journal.lookup(_id)!.remoteName, '$_day-8-$_id.venera');
  });

  test(
    'missing strong ETag retains cleanup and retries without another PUT',
    () async {
      final old = '$_day-2-other-device.venera';
      f.remote.files[old] = [9];
      f.remote.withEtag = false;
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.commitState, DataSyncCommitState.applied);
      expect(error.toString(), contains('strong ETag'));
      expect(f.journal.lookup(_id)!.retention.single.name, old);
      expect(f.remote.files, contains(old));
      expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
      f.remote.withEtag = true;
      f.reopen();
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.applied,
      );
      expect(f.remote.puts, 1);
      expect(f.exports, 1);
      expect(f.remote.files, isNot(contains(old)));
    },
  );

  test('changed retention content is never deleted', () async {
    final old = '$_day-2-legacy.venera';
    f.remote.files[old] = [9];
    final executor = f.executor(
      observer: (event) {
        if (event.phase == 'confirmed') f.remote.files[old] = [42];
      },
    );
    expect(await executor.upload(_id, f.scope), DataSyncCommitState.applied);
    expect(f.remote.files[old], [42]);
    expect(f.remote.removed, isEmpty);
  });

  test(
    '412 retention keeps unchanged original pending for a later retry',
    () async {
      final old = '$_day-2-legacy.venera';
      f.remote.files[old] = [9];
      f.remote.preconditionRemove = true;
      final failure = await _failure(f.executor().upload(_id, f.scope));
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(f.journal.lookup(_id)!.retention, hasLength(1));
      f.remote.preconditionRemove = false;
      expect(
        await f.executor().recover(_id, f.scope),
        DataSyncCommitState.applied,
      );
      expect(f.remote.puts, 1);
    },
  );

  test('snapshot is kept until actual remote close finishes', () async {
    final close = Completer<void>();
    final closing = Completer<void>();
    f.remote.closeAction = () {
      closing.complete();
      return close.future;
    };
    final work = f.executor().upload(_id, f.scope);
    await closing.future;
    expect(f.journal.snapshotFile(_id).existsSync(), isTrue);
    expect(f.journal.lookup(_id)!.isTerminal, isFalse);
    close.complete();
    expect(await work, DataSyncCommitState.applied);
    expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
  });

  test('failed close preserves snapshot and original diagnostic', () async {
    final error = StateError('native close failed');
    final stack = StackTrace.fromString('native close stack');
    f.remote.closeAction = () => Error.throwWithStackTrace(error, stack);
    final failure = await _failure(f.executor().upload(_id, f.scope));
    expect(failure.commitState, DataSyncCommitState.applied);
    expect(failure.failures.single.error, same(error));
    expect(failure.failures.single.stack.toString(), stack.toString());
    expect(f.journal.snapshotFile(_id).existsSync(), isTrue);
    f.remote.closeAction = null;
    f.reopen();
    expect(
      await f.executor().recover(_id, f.scope),
      DataSyncCommitState.applied,
    );
    expect(f.remote.puts, 1);
    expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
  });

  test(
    'sync-time retry reuses committedAt after snapshot cleanup and reopen',
    () async {
      f.failTime = true;
      final failure = await _failure(f.executor().upload(_id, f.scope));
      expect(failure.commitState, DataSyncCommitState.applied);
      expect(f.journal.lookup(_id)!.committedAt, _date.millisecondsSinceEpoch);
      expect(f.journal.snapshotFile(_id).existsSync(), isFalse);
      f.failTime = false;
      f.reopen();
      expect(
        await f
            .executor(now: () => _date.add(const Duration(days: 1)))
            .recover(_id, f.scope),
        DataSyncCommitState.applied,
      );
      expect(f.times, [
        _date.millisecondsSinceEpoch,
        _date.millisecondsSinceEpoch,
      ]);
      expect(f.exports, 1);
      expect(f.remote.puts, 1);
    },
  );

  test(
    'wrong endpoint leaves the preparing operation and files unchanged',
    () async {
      f.journal.save(
        DataSyncUploadRecord(
          operationId: _id,
          endpointFingerprint: f.fingerprint,
        ),
      );
      final before = f.journal.lookup(_id)!.toJson();
      final failure = await _failure(
        f
            .executor(
              fingerprint: dataSyncEndpointFingerprint(['other', 'u', 'p']),
            )
            .recover(_id, f.scope),
      );
      expect(failure.commitState, DataSyncCommitState.recoveryRequired);
      expect(f.journal.lookup(_id)!.toJson(), before);
      expect(f.opens, 0);
    },
  );

  test('strict journal schema rejects bad records before modifying files', () {
    final path = p.join(f.journal.dataPath, '.data-sync-upload.sqlite');
    f.journal.close();
    final db = sqlite3.open(path);
    db.execute('INSERT INTO upload_operations(id, record) VALUES (?, ?)', [
      _id,
      '{"phase":"finished"}',
    ]);
    db.dispose();
    expect(
      () => DataSyncUploadJournal.open(p.dirname(path)),
      throwsFormatException,
    );
  });

  test('UUID derived paths reject traversal', () {
    expect(() => f.journal.snapshotFile('../foreign'), throwsFormatException);
    expect(() => f.journal.lookup('../foreign'), throwsFormatException);
  });

  test(
    'partial export and its staging are cleaned after exporter failure',
    () async {
      f.exportAction = (destination) async {
        await destination.writeAsString('partial');
        final staging = Directory(
          p.join(destination.parent.path, 'export-staging', 'sources'),
        );
        await staging.create(recursive: true);
        await File(p.join(staging.path, 'source.js')).writeAsString('partial');
        throw StateError('archive encoder failed');
      };
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.commitState, DataSyncCommitState.notApplied);
      expect(f.journal.operationDirectory(_id).existsSync(), isFalse);
      expect(f.journal.lookup(_id)!.isTerminal, isTrue);
      expect(f.remote.puts, 0);
    },
  );

  test(
    'unknown owned-directory entries block cleanup without deleting evidence',
    () async {
      f.exportAction = (destination) async {
        await destination.writeAsString('partial');
        await File(
          p.join(destination.parent.path, 'unknown'),
        ).writeAsString('preserve');
        throw StateError('archive encoder failed');
      };
      final error = await _failure(f.executor().upload(_id, f.scope));
      expect(error.failures, hasLength(2));
      expect(f.journal.snapshotFile(_id).readAsStringSync(), 'partial');
      expect(f.journal.lookup(_id)!.isTerminal, isFalse);
    },
  );

  test(
    'acknowledgement never reacquires a path already durably cleaned',
    () async {
      expect(
        await f.executor().upload(_id, f.scope),
        DataSyncCommitState.applied,
      );
      final directory = f.journal.operationDirectory(_id)..createSync();
      final foreign = File(p.join(directory.path, 'snapshot.venera'))
        ..writeAsStringSync('new owner');
      await f.journal.acknowledge(_id);
      expect(foreign.readAsStringSync(), 'new owner');
    },
  );

  test('endpoint fingerprint preserves exact endpoint and credentials', () {
    expect(
      dataSyncEndpointFingerprint(['url', 'a', 'bc']),
      isNot(dataSyncEndpointFingerprint(['url', 'ab', 'c'])),
    );
    expect(
      dataSyncEndpointFingerprint(['url/', 'a', 'bc']),
      isNot(dataSyncEndpointFingerprint(['url', 'a', 'bc'])),
    );
  });
}

Future<DataSyncFailure> _failure(Future<Object?> work) async {
  try {
    await work;
  } on DataSyncFailure catch (error) {
    return error;
  }
  throw StateError('Expected upload failure');
}

class _Fixture {
  _Fixture() {
    journal = DataSyncUploadJournal.open(p.join(root.path, 'data'));
  }
  final root = Directory.systemTemp.createTempSync('sync-upload-executor-');
  late DataSyncUploadJournal journal;
  final scope = RequestScope();
  final remote = _Remote();
  final fingerprint = dataSyncEndpointFingerprint([
    'https://example.invalid',
    'u',
    'p',
  ]);
  final times = <int>[];
  int exports = 0;
  int versions = 0;
  int opens = 0;
  bool failTime = false;
  Object? prepareError;
  Future<void> Function(File)? exportAction;

  DataSyncUploadExecutor executor({
    DataSyncUploadObserver? observer,
    DateTime Function()? now,
    String? fingerprint,
  }) => DataSyncUploadExecutor(
    journal: journal,
    endpointFingerprint: fingerprint ?? this.fingerprint,
    openRemote: () {
      opens++;
      return remote;
    },
    prepareVersion: () async {
      versions++;
      if (prepareError != null) throw prepareError!;
      return 8;
    },
    exportData: (destination) async {
      exports++;
      if (exportAction != null) return exportAction!(destination);
      await destination.writeAsBytes([1, 2, 3]);
    },
    recordSyncTime: (time) async {
      times.add(time);
      if (failTime) throw StateError('time write failed');
    },
    now: now ?? () => _date,
    observer: observer,
  );
  void reopen() {
    final path = journal.dataPath;
    journal.close();
    journal = DataSyncUploadJournal.open(path);
  }

  void blockPhase(String phase) {
    if (!{'prepared', 'putPending', 'confirmed'}.contains(phase)) {
      throw ArgumentError.value(phase, 'phase');
    }
    final db = sqlite3.open(
      p.join(journal.dataPath, '.data-sync-upload.sqlite'),
    );
    try {
      db.execute('''
        CREATE TRIGGER reject_upload_phase BEFORE UPDATE ON upload_operations
        WHEN json_extract(NEW.record, '\$.phase') = '$phase'
        BEGIN SELECT RAISE(FAIL, 'injected upload journal write failure'); END;
      ''');
    } finally {
      db.dispose();
    }
  }

  void unblockPhase() {
    final db = sqlite3.open(
      p.join(journal.dataPath, '.data-sync-upload.sqlite'),
    );
    try {
      db.execute('DROP TRIGGER reject_upload_phase');
    } finally {
      db.dispose();
    }
  }

  void dispose() {
    journal.close();
    scope.dispose();
    root.deleteSync(recursive: true);
  }
}

class _Remote implements DataSyncRemote {
  final files = <String, List<int>>{};
  final removed = <String>{};
  final probed = <String>[];
  bool withEtag = true;
  bool preconditionRemove = false;
  int puts = 0;
  Future<void> Function()? closeAction;
  @override
  Future<List<String>> listNames() async => files.keys.toList();
  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) async {
    probed.add(name);
    final bytes = files[name];
    if (bytes == null) return const DataSyncArchiveMissing();
    return DataSyncArchivePresent(
      sha256: crypto.sha256.convert(bytes).toString(),
      length: bytes.length,
      strongEtag: withEtag ? '"${bytes.join()}"' : null,
    );
  }

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    puts++;
    if (files.containsKey(name)) {
      return DataSyncArchiveCreateResult.preconditionFailed;
    }
    files[name] = await source.readAsBytes();
    return DataSyncArchiveCreateResult.created;
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    if (preconditionRemove) {
      return DataSyncArchiveRemoveResult.preconditionFailed;
    }
    removed.add(name);
    return files.remove(name) == null
        ? DataSyncArchiveRemoveResult.missing
        : DataSyncArchiveRemoveResult.removed;
  }

  @override
  Future<void> readToFile(String name, String path) =>
      throw UnsupportedError('upload only');
  @override
  Future<void> dispose() async => closeAction?.call();
}
