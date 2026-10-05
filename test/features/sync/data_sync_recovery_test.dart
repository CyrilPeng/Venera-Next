import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

import '../../support/data_sync_fixture.dart';

void main() {
  test(
    'applied receipt restores the original draft and fixed time without transfer',
    () async {
      final f = _Fixture()..installReceipt();
      addTearDown(f.dispose);
      f.recovery.onNotify = f.controller.onDataChanged;
      expect((await f.controller.uploadData()).success, isTrue);
      expect(f.settings['webdav'], _draft);
      expect(f.settings['disableSyncFields'], 'local-only');
      expect(f.recovery.times, [_committedAt]);
      expect(f.recovery.notifications, 1);
      expect(f.controller.hasPendingChanges, isTrue);
      expect([f.uploads, f.downloads], [0, 0]);
      expect(f.durableImplicit['webdavSyncOperation'], isNull);
      expect(f.recovery.receipts, isEmpty);
      expect(
        f.events.indexOf('clear marker'),
        lessThan(f.events.indexOf('ack receipt')),
      );
    },
  );

  test(
    'rolled back configuration restores its durable checkpoint and preserves edits',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.implicit['webdavSyncLastAttempt'] = 77;
      f.implicit['webdavSyncPending'] = false;
      final previous = f.preferences.capture();
      f.installReceipt(
        state: DataSyncCommitState.notApplied,
        previous: previous,
      );
      f.settings['webdav'] = List<String>.of(_draft);
      f.settings['disableSyncFields'] = 'local-only';
      f.controller.onDataChanged();
      expect((await f.controller.downloadData()).success, isTrue);
      expect(f.settings['webdav'], _old);
      expect(f.settings['disableSyncFields'], 'old-field');
      expect(f.controller.currentMode, DataSyncMode.manual);
      expect(f.implicit['webdavSyncLastAttempt'], 77);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.recovery.notifications, 0);
      expect(f.recovery.times, isEmpty);
      expect([f.uploads, f.downloads], [0, 0]);
      expect(f.recovery.receipts, isEmpty);
    },
  );

  for (final stage in ['read', 'time', 'settings', 'receipt', 'clear', 'ack']) {
    test(
      '$stage recovery failure is retryable without repeating business or successful follow-up',
      () async {
        final f = _Fixture()..installReceipt();
        addTearDown(f.dispose);
        final error = StateError('$stage failed');
        final stack = StackTrace.fromString('$stage original stack');
        var failed = false;
        void failOnce() {
          if (!failed) {
            failed = true;
            Error.throwWithStackTrace(error, stack);
          }
        }

        switch (stage) {
          case 'read':
            f.recovery.beforeRead = failOnce;
          case 'time':
            f.recovery.beforeTime = failOnce;
          case 'settings':
            f.beforeSettings = failOnce;
          case 'receipt':
            f.beforePersist = () {
              final raw = f.implicit['webdavSyncOperation'];
              if (raw != null &&
                  DataSyncOperation.fromJson(raw).followUpComplete) {
                failOnce();
              }
            };
          case 'clear':
            f.beforePersist = () {
              if (f.implicit['webdavSyncOperation'] == null) failOnce();
            };
          case 'ack':
            f.recovery.beforeAck = failOnce;
        }
        final failedResult = await f.controller.downloadData();
        expect(failedResult.error, isTrue);
        final failure = failedResult.failure! as DataSyncFailure;
        expect(
          failure.failures.any(
            (entry) =>
                identical(entry.error, error) && identical(entry.stack, stack),
          ),
          isTrue,
        );
        expect(f.recovery.receipts, hasLength(1));
        expect([f.uploads, f.downloads], [0, 0]);
        final savesBeforeRetry = f.events
            .where((event) => event == 'save settings')
            .length;
        expect((await f.controller.uploadData()).success, isTrue);
        expect([f.uploads, f.downloads], [0, 0]);
        expect(f.recovery.notifications, 1);
        expect(f.recovery.times, everyElement(_committedAt));
        expect(f.recovery.times.length, stage == 'time' ? 2 : 1);
        expect(f.controller.hasPendingChanges, isTrue);
        expect(f.recovery.receipts, isEmpty);
        if (stage == 'ack') {
          expect(
            f.events.where((event) => event == 'save settings').length,
            savesBeforeRetry,
          );
        }
      },
    );
  }

  test('concurrent directions share one recovered continuation', () async {
    final f = _Fixture()..installReceipt();
    addTearDown(f.dispose);
    final gate = Completer<void>();
    f.recovery.beforeTime = () => gate.future;
    final first = f.controller.downloadData();
    final second = f.controller.uploadData();
    await pumpEventQueue();
    final third = f.controller.downloadData();
    expect(f.recovery.notifications, 1);
    expect(f.recovery.times, [_committedAt]);
    expect([f.uploads, f.downloads], [0, 0]);
    expect(f.recovery.receipts, hasLength(1));
    gate.complete();
    expect(
      (await Future.wait([
        first,
        second,
        third,
      ])).every((result) => result.success),
      isTrue,
    );
    expect(f.recovery.times, [_committedAt]);
    expect(f.recovery.acks, 1);
  });

  test(
    'restart after marker clear retries only orphan acknowledgement and keeps pending',
    () async {
      final f = _Fixture()..installReceipt();
      addTearDown(f.dispose);
      f.recovery.beforeAck = () => throw StateError('ack interrupted');
      expect((await f.controller.downloadData()).error, isTrue);
      expect(f.durableImplicit['webdavSyncOperation'], isNull);
      expect(f.recovery.receipts, hasLength(1));
      final events = f.events.length;
      f.recovery.beforeAck = null;
      f.rebuild();
      f.controller.start();
      await pumpEventQueue();
      expect(f.recovery.receipts, isEmpty);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.recovery.times, [_committedAt]);
      expect(f.recovery.notifications, 1);
      expect(f.events.sublist(events), ['ack receipt']);
      expect([f.uploads, f.downloads], [0, 0]);
    },
  );

  for (final kind in [
    'legacy',
    'corrupt',
    'mismatch',
    'duplicate',
    'upload',
    'missing time',
    'negative time',
    'overflow time',
    'missing receipt',
    'unfinished receipt',
  ]) {
    test('$kind marker or receipt cannot authorize recovery', () async {
      final f = _Fixture()..installReceipt();
      addTearDown(f.dispose);
      final json = f.implicit['webdavSyncOperation'] as Map<String, dynamic>;
      switch (kind) {
        case 'legacy':
          json['version'] = 1;
        case 'corrupt':
          json.remove('id');
        case 'mismatch':
          json['id'] = 'another-operation';
        case 'duplicate':
          f.recovery.receipts.add(f.recovery.receipts.single);
        case 'upload':
          json['direction'] = 'upload';
        case 'missing time':
        case 'negative time':
        case 'overflow time':
          f.recovery.receipts[0] = DataSyncImportReceipt(
            id: 'receipt',
            syncOperationId: 'operation',
            commitState: DataSyncCommitState.applied,
            committedAt: switch (kind) {
              'negative time' => -1,
              'overflow time' => 9223372036854775807,
              _ => null,
            },
          );
        case 'missing receipt':
          f.recovery.receipts.clear();
        case 'unfinished receipt':
          f.recovery.receipts[0] = const DataSyncImportReceipt(
            id: 'receipt',
            syncOperationId: 'operation',
            commitState: DataSyncCommitState.recoveryRequired,
            committedAt: null,
          );
      }
      final before = jsonEncode(json);
      final result = await f.controller.downloadData();
      expect(result.error, isTrue);
      expect(
        (result.failure! as DataSyncFailure).commitState,
        DataSyncCommitState.recoveryRequired,
      );
      expect(jsonEncode(f.implicit['webdavSyncOperation']), before);
      expect(f.recovery.acks, 0);
      expect(f.recovery.notifications, 0);
      expect(f.recovery.times, isEmpty);
      expect([f.uploads, f.downloads], [0, 0]);
    });
  }

  test(
    'recovered applied state permits a later realtime upload of conservatively pending data',
    () async {
      final f = _Fixture()..installReceipt(mode: 'realtime');
      addTearDown(f.dispose);
      f.controller.start();
      await pumpEventQueue();
      await f.controller.waitForUpload();
      expect(f.recovery.receipts, isEmpty);
      expect(f.recovery.times, [_committedAt]);
      expect([f.uploads, f.downloads], [1, 0]);
      expect(f.controller.hasPendingChanges, isFalse);
    },
  );

  test(
    'controller forwards the persisted operation id and acknowledges normal import',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.transfer.onDownload = () async {
        f.downloads++;
        final operation = DataSyncOperation.fromJson(
          f.durableImplicit['webdavSyncOperation'],
        );
        expect(f.transfer.downloadOperationId, operation.id);
        expect(operation.version, 2);
        f.recovery.receipts.add(
          DataSyncImportReceipt(
            id: 'new receipt',
            syncOperationId: operation.id,
            commitState: DataSyncCommitState.applied,
            committedAt: _committedAt,
          ),
        );
        return const Res(true);
      };
      expect((await f.controller.downloadData()).success, isTrue);
      expect(f.recovery.receipts, isEmpty);
      expect([f.uploads, f.downloads], [0, 1]);
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'disposed flush' : 'exit'} joins a normal import receipt read and retains its late failure',
      () async {
        final f = _Fixture();
        addTearDown(f.dispose);
        final readGate = Completer<void>();
        final error = StateError('late terminal receipt read failed');
        final stack = StackTrace.fromString('terminal receipt read stack');
        f.transfer.onDownload = () async {
          f.downloads++;
          f.recovery.beforeRead = () async {
            await readGate.future;
            Error.throwWithStackTrace(error, stack);
          };
          return const Res(true);
        };
        final attempt = f.controller.downloadData();
        await pumpEventQueue();
        expect(f.downloads, 1);
        var joined = false;
        final Future<Object?> closing;
        if (dispose) {
          f.controller.dispose();
          closing = f.controller.flushPersistence().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        } else {
          closing = f.controller.prepareForExit().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        }
        final observed = closing.then((value) {
          joined = true;
          return value;
        });
        await pumpEventQueue();
        expect(joined, isFalse);
        readGate.complete();
        expect((await attempt).error, isTrue);
        final failure = await observed as DataSyncFailure;
        expect(
          failure.failures.any(
            (entry) =>
                identical(entry.error, error) && identical(entry.stack, stack),
          ),
          isTrue,
        );
        expect(f.durableImplicit['webdavSyncOperation'], isNotNull);
        expect(f.settings['webdav'], _old);
        expect(f.recovery.notifications, 0);
        expect(f.recovery.acks, 0);
      },
    );

    test(
      '${dispose ? 'disposed flush' : 'exit'} retains a failed recovery read after joining it',
      () async {
        final f = _Fixture()..installReceipt();
        addTearDown(f.dispose);
        final readGate = Completer<void>();
        final error = StateError('late recovery read failed');
        final stack = StackTrace.fromString('late read stack');
        f.recovery.beforeRead = () async {
          await readGate.future;
          Error.throwWithStackTrace(error, stack);
        };
        final attempt = f.controller.downloadData();
        await pumpEventQueue();
        final Future<Object?> closing;
        if (dispose) {
          f.controller.dispose();
          closing = f.controller.flushPersistence().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        } else {
          closing = f.controller.prepareForExit().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        }
        readGate.complete();
        expect((await attempt).error, isTrue);
        final failure = await closing as DataSyncFailure;
        expect(
          failure.failures.any(
            (entry) =>
                identical(entry.error, error) && identical(entry.stack, stack),
          ),
          isTrue,
        );
        expect(f.settings['webdav'], _old);
        expect(f.recovery.notifications, 0);
        expect(f.recovery.acks, 0);
        expect(f.recovery.receipts, hasLength(1));
      },
    );

    test(
      '${dispose ? 'dispose and flush' : 'exit preparation'} joins recovery read without applying late results',
      () async {
        final f = _Fixture()..installReceipt();
        addTearDown(f.dispose);
        final readGate = Completer<void>();
        f.recovery.beforeRead = () => readGate.future;
        final attempt = f.controller.downloadData();
        await pumpEventQueue();
        var done = false;
        void Function()? release;
        final Future<void> joined;
        if (dispose) {
          f.controller.dispose();
          joined = f.controller.flushPersistence().then((_) => done = true);
        } else {
          joined = f.controller.prepareForExit().then((value) {
            release = value;
            done = true;
          });
        }
        await pumpEventQueue();
        expect(done, isFalse);
        expect(f.settings['webdav'], _old);
        readGate.complete();
        expect((await attempt).error, isTrue);
        await joined;
        expect(done, isTrue);
        expect(f.settings['webdav'], _old);
        expect(f.recovery.notifications, 0);
        expect(f.recovery.times, isEmpty);
        expect(f.recovery.acks, 0);
        expect(f.recovery.receipts, hasLength(1));
        if (!dispose) {
          release!();
          expect((await f.controller.downloadData()).success, isTrue);
          expect(f.recovery.times, [_committedAt]);
        }
      },
    );

    test(
      '${dispose ? 'dispose and flush' : 'exit preparation'} joins an accepted acknowledgement and preserves its error',
      () async {
        final f = _Fixture()..installReceipt();
        addTearDown(f.dispose);
        final ackGate = Completer<void>();
        final error = StateError('late acknowledgement failure');
        final stack = StackTrace.fromString('acknowledgement stack');
        f.recovery.beforeAck = () async {
          await ackGate.future;
          Error.throwWithStackTrace(error, stack);
        };
        final attempt = f.controller.downloadData();
        await pumpEventQueue();
        expect(f.recovery.acks, 1);
        expect(f.durableImplicit['webdavSyncOperation'], isNull);
        var joined = false;
        final Future<Object?> closing;
        if (dispose) {
          f.controller.dispose();
          closing = f.controller.flushPersistence().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        } else {
          closing = f.controller.prepareForExit().then<Object?>(
            (_) => null,
            onError: (Object value) => value,
          );
        }
        final observed = closing.then((result) {
          joined = true;
          return result;
        });
        await pumpEventQueue();
        expect(joined, isFalse);
        ackGate.complete();
        expect((await attempt).error, isTrue);
        final closeError = await observed as DataSyncFailure;
        expect(
          closeError.failures.any(
            (entry) =>
                identical(entry.error, error) && identical(entry.stack, stack),
          ),
          isTrue,
        );
        expect(f.recovery.receipts, hasLength(1));
        expect(f.recovery.notifications, 1);
        expect(f.recovery.times, [_committedAt]);
        if (!dispose) {
          f.recovery.beforeAck = null;
          expect((await f.controller.downloadData()).success, isTrue);
          final release = await f.controller.prepareForExit();
          release();
          expect(f.recovery.receipts, isEmpty);
        }
      },
    );
  }
}

const _old = ['https://old.test', 'old', 'password'];
const _draft = ['https://new.test', 'new', 'password'];
const _committedAt = 123456789;

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class _Fixture {
  Map<String, dynamic> settings = {
    'webdav': List<String>.of(_old),
    'disableSyncFields': 'old-field',
  };
  Map<String, dynamic> implicit = {
    'webdavSyncMode': 'manual',
    'webdavSyncPending': false,
  };
  Map<String, dynamic> durableSettings = {};
  Map<String, dynamic> durableImplicit = {};
  final events = <String>[];
  final recovery = _Recovery();
  final transfer = ControlledSyncTransfer();
  DataSyncController? _controller;
  FutureOr<void> Function()? beforeSettings;
  FutureOr<void> Function()? beforePersist;
  int uploads = 0;
  int downloads = 0;

  _Fixture() {
    durableSettings = _copy(settings);
    durableImplicit = _copy(implicit);
    recovery.afterAck = () {
      expect(durableImplicit['webdavSyncOperation'], isNull);
      events.add('ack receipt');
    };
    transfer.onUpload = () async {
      uploads++;
      return const Res(true);
    };
    transfer.onDownload = () async {
      downloads++;
      return const Res(false);
    };
  }

  SyncPreferenceStore get preferences => SyncPreferenceStore(
    readSetting: (key) => settings[key],
    writeSetting: (key, value) => settings[key] = value,
    implicitData: () => implicit,
  );

  DataSyncController get controller => _controller ??= DataSyncController(
    preferences: preferences,
    transfer: () => transfer,
    importRecovery: recovery,
    saveSettings: () async {
      events.add('save settings');
      await beforeSettings?.call();
      durableSettings = _copy(settings);
    },
    persistImplicit: () async {
      await beforePersist?.call();
      durableImplicit = _copy(implicit);
      events.add(
        implicit['webdavSyncOperation'] == null
            ? 'clear marker'
            : 'save marker',
      );
    },
    observeChanges: (_) => () {},
  );

  void installReceipt({
    DataSyncCommitState state = DataSyncCommitState.applied,
    SyncPreferenceCheckpoint? previous,
    String mode = 'manual',
  }) {
    final operation = DataSyncOperation(
      id: 'operation',
      direction: DataSyncDirection.download,
      connection: _draft,
      excludedFields: 'local-only',
      mode: mode,
      intervalMinutes: 30,
      pendingBefore: false,
      generation: 0,
      commitState: DataSyncCommitState.notApplied,
      followUpComplete: false,
      configurationChange: previous != null,
      previousConfiguration: previous,
    );
    implicit['webdavSyncOperation'] = _copy(operation.toJson());
    recovery.receipts.add(
      DataSyncImportReceipt(
        id: 'receipt',
        syncOperationId: operation.id,
        commitState: state,
        committedAt: state == DataSyncCommitState.applied ? _committedAt : null,
      ),
    );
    durableImplicit = _copy(implicit);
  }

  void rebuild() {
    dispose();
    settings = _copy(durableSettings);
    implicit = _copy(durableImplicit);
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
  }
}

class _Recovery implements DataSyncImportRecovery {
  final receipts = <DataSyncImportReceipt>[];
  final times = <int>[];
  int notifications = 0;
  int acks = 0;
  void Function()? onNotify;
  FutureOr<void> Function()? beforeRead;
  FutureOr<void> Function()? beforeTime;
  FutureOr<void> Function()? beforeAck;
  void Function()? afterAck;

  @override
  Future<List<DataSyncImportReceipt>> readReceipts() async {
    await beforeRead?.call();
    return List.of(receipts);
  }

  @override
  Future<void> acknowledge(String receiptId) async {
    acks++;
    await beforeAck?.call();
    afterAck?.call();
    receipts.removeWhere((receipt) => receipt.id == receiptId);
  }

  @override
  void notifyImported() {
    notifications++;
    onNotify?.call();
  }

  @override
  Future<void> recordSyncTime(int milliseconds) async {
    times.add(milliseconds);
    await beforeTime?.call();
  }
}
