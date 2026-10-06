import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_content_journal.dart';
import 'package:venera_next/features/sync/data_sync_content_recovery.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/features/sync/data_sync_upload_journal.dart';

const id = '11111111-1111-4111-8111-111111111111';
const nextId = '22222222-2222-4222-8222-222222222222';
const connection = ['https://example.com', '', ''];

void main() {
  late Directory root;
  late DataSyncContentJournal contents;
  late DataSyncUploadJournal uploads;
  late AppDataImportJournal imports;
  late DataSyncContentRecovery recovery;
  late SqliteDataSyncOwnership owner;
  final scope = DataSyncContentScope(
    endpoint: dataSyncEndpointFingerprint(connection),
    excludedFields: '',
    archiveSyncEnabled: false,
  );
  void begin({String operationId = id, String direction = 'download'}) =>
      contents.begin(
        id: operationId,
        direction: direction,
        scope: scope,
        before: 'a' * 64,
      );
  DataSyncOperation marker({
    String direction = 'download',
    String excluded = '',
    int version = 4,
  }) {
    final operation = DataSyncOperation(
      id: id,
      direction: DataSyncDirection.values.byName(direction),
      connection: connection,
      excludedFields: excluded,
      mode: 'manual',
      intervalMinutes: 15,
      pendingBefore: false,
      generation: 0,
      commitState: DataSyncCommitState.notApplied,
      followUpComplete: false,
      version: version,
    );
    File('${root.path}/implicitData.json').writeAsStringSync(
      jsonEncode({'webdavSyncOperation': operation.toJson()}),
    );
    return operation;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('sync-content-recovery-');
    owner = SqliteDataSyncOwnership(() => root.path)..acquire();
    contents = DataSyncContentJournal.open(root.path);
    uploads = DataSyncUploadJournal.open(root.path);
    imports = AppDataImportJournal.open(root.path);
    recovery = DataSyncContentRecovery();
  });
  tearDown(() {
    recovery.close();
    imports.close();
    uploads.close();
    contents.close();
    owner.release();
    root.deleteSync(recursive: true);
  });

  test(
    'failed recovery close is retained and retried before opening another journal',
    () async {
      begin();
      var opens = 0;
      late _FailingImports retained;
      recovery = DataSyncContentRecovery(
        openImports: (path) {
          opens++;
          return retained = _FailingImports(AppDataImportJournal.open(path));
        },
      );
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.records, isEmpty);
      expect(retained.closeAttempts, 1);
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(opens, 1);
      expect(retained.closeAttempts, 2);
      recovery.close();
      expect(retained.closeAttempts, 3);
      recovery.close();
      expect(retained.closeAttempts, 3);
    },
  );

  for (final direction in ['upload', 'download']) {
    test('candidate before marker is safely retired: $direction', () async {
      begin(direction: direction);
      expect(await recovery.recover(root.path, null), isFalse);
      expect(contents.records, isEmpty);
      expect(contents.baseline(scope), isNull);
    });
  }

  test(
    'active download before import stays recoverable without a receipt',
    () async {
      begin();
      final active = marker();
      expect(await recovery.recover(root.path, active), isTrue);
      expect(contents.lookup(id)!.completedState, isNull);
      contents.completeNotApplied(id);
      expect(await recovery.recover(root.path, active), isTrue);
      expect(
        () => contents.verifyBeforeImport(id, 'a' * 64),
        throwsA(isA<DataSyncContentConflict>()),
      );
      expect(() => contents.recordSnapshot(id, 'b' * 64), throwsStateError);
      expect(() => contents.confirm(id), throwsStateError);
    },
  );

  test(
    'pending import intent is never mistaken for an unstarted download',
    () async {
      begin();
      await imports.prepare(resources: {}, syncOperationId: id);
      final active = marker();
      expect(imports.receipts, isEmpty);
      expect(await recovery.recover(root.path, active), isFalse);
      File('${root.path}/implicitData.json').deleteSync();
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.lookup(id)!.completedState, isNull);
      expect(imports.containsSyncOperation(id), isTrue);
    },
  );

  for (final completed in [false, true]) {
    test(
      'rolled back receipt retires orphan, durable decision=$completed',
      () async {
        begin();
        final transaction = await imports.prepare(
          resources: {},
          syncOperationId: id,
        );
        await transaction.markRolledBack();
        if (completed) contents.completeNotApplied(id);
        expect(await recovery.recover(root.path, null), isFalse);
        expect(imports.receipts, isEmpty);
        expect(contents.records, isEmpty);
        expect(contents.baseline(scope), isNull);
        await recovery.recover(root.path, null);
      },
    );
  }

  for (final receiptPresent in [false, true]) {
    test(
      'confirmed orphan preserves baseline after marker or receipt ack: $receiptPresent',
      () async {
        begin();
        contents.recordSnapshot(id, 'b' * 64);
        final transaction = await imports.prepare(
          resources: {},
          syncOperationId: id,
        );
        await transaction.markApplied(DateTime.now().millisecondsSinceEpoch);
        contents.confirm(id);
        if (!receiptPresent) await imports.acknowledge(transaction.id);
        await recovery.recover(root.path, null);
        expect(contents.records, isEmpty);
        expect(imports.receipts, isEmpty);
        expect(contents.baseline(scope), 'b' * 64);
      },
    );
  }

  test(
    'not-applied completion survives receipt ack even with a snapshot',
    () async {
      begin();
      contents.recordSnapshot(id, 'b' * 64);
      contents.completeNotApplied(id);
      await recovery.recover(root.path, null);
      expect(contents.records, isEmpty);
      expect(contents.baseline(scope), isNull);
    },
  );

  test(
    'applied receipt without durable content decision is retained',
    () async {
      begin();
      contents.recordSnapshot(id, 'b' * 64);
      final transaction = await imports.prepare(
        resources: {},
        syncOperationId: id,
      );
      await transaction.markApplied(DateTime.now().millisecondsSinceEpoch);
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.lookup(id)!.confirmed, isFalse);
      expect(imports.receipts, hasLength(1));
      expect(contents.baseline(scope), isNull);
    },
  );

  test(
    'one ambiguous orphan does not prevent proven independent cleanup',
    () async {
      begin();
      contents.recordSnapshot(id, 'b' * 64);
      begin(operationId: nextId);
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.records.map((r) => r.id), [id]);
    },
  );

  test('confirmed older orphan does not replace the newer baseline', () async {
    begin();
    contents.recordSnapshot(id, 'b' * 64);
    contents.confirm(id);
    begin(operationId: nextId);
    contents.recordSnapshot(nextId, 'c' * 64);
    contents.confirm(nextId);
    contents.acknowledge(nextId);
    await recovery.recover(root.path, null);
    expect(contents.records, isEmpty);
    expect(contents.baseline(scope), 'c' * 64);
  });

  test(
    'legacy confirmed payload is cleaned only with its valid baseline',
    () async {
      begin();
      contents.recordSnapshot(id, 'b' * 64);
      contents.confirm(id);
      _editPayload(root.path, (payload) {
        payload['version'] = 1;
        payload.remove('completedState');
      });
      expect(contents.lookup(id)!.completedState, DataSyncCommitState.applied);
      await recovery.recover(root.path, null);
      expect(contents.records, isEmpty);
      expect(contents.baseline(scope), 'b' * 64);
    },
  );

  test(
    'legacy payload cannot inject an unchecked completion decision',
    () async {
      begin();
      _editPayload(root.path, (payload) {
        payload['version'] = 1;
        payload['completedState'] = 'notApplied';
      });
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
    },
  );

  for (final sql in [
    'DELETE FROM content_baselines',
    "UPDATE content_baselines SET digest = 'bad'",
  ]) {
    test(
      'missing or damaged baseline retains confirmed candidate: $sql',
      () async {
        begin();
        contents.recordSnapshot(id, 'b' * 64);
        contents.confirm(id);
        final db = sqlite3.open(
          '${root.path}/${DataSyncContentJournal.fileName}',
        );
        try {
          db.execute(sql);
        } finally {
          db.dispose();
        }
        await expectLater(
          recovery.recover(root.path, null),
          throwsA(isA<DataSyncFailure>()),
        );
        expect(contents.lookup(id)!.confirmed, isTrue);
      },
    );
  }

  test(
    'disk marker disagreement cannot clear an in-flight candidate',
    () async {
      begin();
      marker();
      await expectLater(recovery.recover(root.path, null), throwsStateError);
      expect(contents.lookup(id), isNotNull);
    },
  );

  test('active v4 marker must have its candidate', () async {
    await expectLater(
      recovery.recover(root.path, marker()),
      throwsA(isA<DataSyncFailure>()),
    );
  });

  for (final version in [1, 2, 3]) {
    test(
      'legacy marker can recover without a v4 candidate: $version',
      () async {
        expect(
          await recovery.recover(root.path, marker(version: version)),
          isFalse,
        );
      },
    );
  }

  test('active marker direction and filter must match candidate', () async {
    begin();
    await expectLater(
      recovery.recover(root.path, marker(direction: 'upload')),
      throwsA(isA<DataSyncFailure>()),
    );
    await expectLater(
      recovery.recover(root.path, marker(excluded: 'language')),
      throwsA(isA<DataSyncFailure>()),
    );
    expect(contents.lookup(id), isNotNull);
  });

  test(
    'wrong endpoint upload receipt is retained without recording completion',
    () async {
      begin(direction: 'upload');
      uploads.save(
        DataSyncUploadRecord(
          operationId: id,
          endpointFingerprint: 'd' * 64,
          phase: 'notApplied',
          sourceCleaned: true,
        ),
      );
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.lookup(id)!.completedState, isNull);
      expect(uploads.lookup(id), isNotNull);
    },
  );

  test(
    'terminal upload receipt can finish an orphan without touching a baseline',
    () async {
      begin(direction: 'upload');
      uploads.save(
        DataSyncUploadRecord(
          operationId: id,
          endpointFingerprint: scope.endpoint,
          phase: 'notApplied',
          sourceCleaned: true,
        ),
      );
      await recovery.recover(root.path, null);
      expect(contents.records, isEmpty);
      expect(uploads.lookup(id), isNull);
    },
  );

  test(
    'unknown upload directory prevents guessing and remains on disk',
    () async {
      begin(direction: 'upload');
      final directory = uploads.operationDirectory(id)..createSync();
      final unknown = File('${directory.path}/unknown')
        ..writeAsStringSync('keep');
      await expectLater(
        recovery.recover(root.path, null),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(contents.lookup(id)!.completedState, isNull);
      expect(unknown.readAsStringSync(), 'keep');
    },
  );
}

class _FailingImports implements AppDataImportJournal {
  _FailingImports(this.inner);
  final AppDataImportJournal inner;
  int closeAttempts = 0;
  @override
  List<AppDataImportReceipt> get receipts => inner.receipts;
  @override
  bool containsSyncOperation(String id) => inner.containsSyncOperation(id);
  @override
  void close() {
    if (++closeAttempts <= 2) throw StateError('injected close failure');
    inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _editPayload(String root, void Function(Map<String, dynamic>) edit) {
  final db = sqlite3.open('$root/${DataSyncContentJournal.fileName}');
  try {
    final payload =
        jsonDecode(
              db
                      .select('SELECT payload FROM content_operations')
                      .single['payload']
                  as String,
            )
            as Map<String, dynamic>;
    edit(payload);
    final encoded = jsonEncode(payload);
    db.execute('UPDATE content_operations SET payload = ?, digest = ?', [
      encoded,
      sha256.convert(utf8.encode(encoded)).toString(),
    ]);
  } finally {
    db.dispose();
  }
}
