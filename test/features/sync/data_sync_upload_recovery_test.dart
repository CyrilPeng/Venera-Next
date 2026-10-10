import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_recovery.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  test(
    'v3 upload recovery keeps the original endpoint and pending edits',
    () async {
      final f = _Fixture()..install();
      addTearDown(f.dispose);
      expect((await f.controller.downloadData()).success, isTrue);
      expect(f.uploads.endpoints, [_draft]);
      expect(f.transfer.uploads, 0);
      expect(f.transfer.downloads, 0);
      expect(f.settings['webdav'], _draft);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.durable['webdavSyncOperation'], isNull);
      expect(f.uploads.acks, ['operation']);
    },
  );

  test(
    'not-applied recovery restores the original configuration checkpoint',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.implicit['webdavSyncLastAttempt'] = 77;
      final previous = f.preferences.capture();
      f.install(previous: previous);
      f.settings['webdav'] = List<String>.of(_draft);
      f.uploads.recoveredState = DataSyncCommitState.notApplied;
      expect((await f.controller.uploadData()).success, isTrue);
      expect(f.settings['webdav'], _old);
      expect(f.implicit['webdavSyncLastAttempt'], 77);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.uploads.acks, ['operation']);
      expect(f.transfer.uploads, 0);
    },
  );

  for (final version in [1, 2]) {
    test(
      'legacy v$version upload remains blocked despite recovery capability',
      () async {
        final f = _Fixture()..install(version: version);
        addTearDown(f.dispose);
        final result = await f.controller.uploadData();
        expect(result.error, isTrue);
        expect(
          (result.failure! as DataSyncFailure).commitState,
          DataSyncCommitState.recoveryRequired,
        );
        expect(f.uploads.recoveries, 0);
        expect(f.uploads.acks, isEmpty);
        expect(f.transfer.uploads, 0);
        expect(f.durable['webdavSyncOperation'], isNotNull);
      },
    );
  }

  test(
    'production-capable upload persists v3 before transfer then clears before ack',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.transfer.onUpload = () async {
        final operation = DataSyncOperation.fromJson(
          f.durable['webdavSyncOperation'],
        );
        expect(operation.version, 3);
        expect(operation.id, f.transfer.operationId);
        f.uploads.terminals[operation.id] = DataSyncCommitState.applied;
      };
      expect((await f.controller.uploadData()).success, isTrue);
      expect(f.transfer.uploads, 1);
      expect(f.uploads.acks, [f.transfer.operationId]);
      expect(f.durable['webdavSyncOperation'], isNull);
    },
  );

  test(
    'an unknown upload with a real continuation retries without starting another transfer',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.transfer.onUpload = () async {
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.recoveryRequired,
          failures: [
            (
              stage: 'PUT',
              error: StateError('response lost'),
              stack: StackTrace.current,
            ),
          ],
          resume: (scope) => f.uploads.recoverUpload(
            WebDavEndpoint(url: _old[0], user: _old[1], password: _old[2]),
            syncOperationId: f.transfer.operationId!,
            scope: scope,
          ),
        );
      };
      expect((await f.controller.uploadData()).error, isTrue);
      expect((await f.controller.downloadData()).success, isTrue);
      expect(f.transfer.uploads, 1);
      expect(f.transfer.downloads, 0);
      expect(f.uploads.recoveries, 1);
      expect(f.uploads.acks, hasLength(1));
    },
  );

  test(
    'concurrent recovery requests share one admitted continuation',
    () async {
      final f = _Fixture()..install();
      addTearDown(f.dispose);
      final gate = Completer<void>();
      f.uploads.beforeRecover = () => gate.future;
      final first = f.controller.uploadData();
      final second = f.controller.downloadData();
      await pumpEventQueue();
      expect(f.uploads.recoveries, 1);
      gate.complete();
      expect((await first).success, isTrue);
      expect((await second).success, isTrue);
      expect(f.uploads.acks, ['operation']);
      expect(f.transfer.uploads, 0);
    },
  );

  test(
    'prepared upload resumes after configuration rollback and restores its applied draft',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.transfer.onUpload = () async {
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.notApplied,
          failures: [
            (
              stage: 'list',
              error: StateError('listing failed'),
              stack: StackTrace.current,
            ),
          ],
          resume: (scope) => f.uploads.recoverUpload(
            WebDavEndpoint(
              url: _draft[0],
              user: _draft[1],
              password: _draft[2],
            ),
            syncOperationId: f.transfer.operationId!,
            scope: scope,
          ),
        );
      };
      expect(
        (await f.controller.configure(
          config: _draft,
          excludedFields: 'local-only',
          syncMode: DataSyncMode.realtime,
          minutes: 30,
          initialUpload: true,
        )).error,
        isTrue,
      );
      expect(f.settings['webdav'], _old);
      expect(f.durable['webdavSyncOperation'], isNotNull);
      expect((await f.controller.downloadData()).success, isTrue);
      expect(f.settings['webdav'], _draft);
      expect(f.settings['disableSyncFields'], 'local-only');
      expect(f.controller.currentMode, DataSyncMode.realtime);
      expect(f.transfer.uploads, 1);
      expect(f.uploads.endpoints, [_draft]);
      expect(f.uploads.acks, hasLength(1));
    },
  );

  for (final rollbackFailure in ['none', 'settings', 'state', 'clear', 'ack']) {
    test(
      'unknown configuration upload restores checkpoint after not-applied recovery; failure=$rollbackFailure',
      () async {
        final f = _Fixture();
        addTearDown(f.dispose);
        f.implicit['webdavSyncLastAttempt'] = 77;
        f.transfer.onUpload = () async {
          throw DataSyncTransferFailure(
            commitState: DataSyncCommitState.recoveryRequired,
            failures: [
              (
                stage: 'PUT',
                error: StateError('response lost'),
                stack: StackTrace.current,
              ),
            ],
            resume: (scope) => f.uploads.recoverUpload(
              WebDavEndpoint(
                url: _draft[0],
                user: _draft[1],
                password: _draft[2],
              ),
              syncOperationId: f.transfer.operationId!,
              scope: scope,
            ),
          );
        };
        expect(
          (await f.controller.configure(
            config: _draft,
            excludedFields: 'local-only',
            syncMode: DataSyncMode.realtime,
            minutes: 30,
            initialUpload: true,
          )).error,
          isTrue,
        );
        expect(f.settings['webdav'], _draft);
        f.uploads.recoveredState = DataSyncCommitState.notApplied;
        var failed = false;
        void failOnce() {
          if (!failed) {
            failed = true;
            throw StateError('rollback interrupted');
          }
        }

        switch (rollbackFailure) {
          case 'settings':
            f.beforeSettings = failOnce;
          case 'state':
            f.beforePersist = failOnce;
          case 'clear':
            f.beforePersist = () {
              if (f.implicit['webdavSyncOperation'] == null) failOnce();
            };
          case 'ack':
            f.uploads.beforeAck = failOnce;
        }
        final recovered = await f.controller.uploadData();
        expect(recovered.error, isTrue);
        expect(
          (recovered.failure! as DataSyncFailure).commitState,
          DataSyncCommitState.notApplied,
        );
        if (rollbackFailure != 'none') {
          expect(failed, isTrue);
          await f.controller.downloadData();
        }
        expect(f.settings['webdav'], _old);
        expect(f.settings['disableSyncFields'], '');
        expect(f.implicit['webdavSyncLastAttempt'], 77);
        expect(f.controller.hasPendingChanges, isTrue);
        expect(f.durable['webdavSyncOperation'], isNull);
        expect(f.uploads.acks, hasLength(1));
        expect(f.transfer.uploads, 1);
        expect(f.transfer.downloads, 0);
      },
    );
  }

  for (final stage in [
    'recover',
    'read terminal',
    'settings',
    'clear',
    'ack',
  ]) {
    test(
      '$stage failure preserves upload evidence and retries only unfinished work',
      () async {
        final f = _Fixture()..install();
        addTearDown(f.dispose);
        var failed = false;
        final error = StateError('$stage failed');
        final stack = StackTrace.fromString('$stage original stack');
        void failOnce() {
          if (!failed) {
            failed = true;
            Error.throwWithStackTrace(error, stack);
          }
        }

        switch (stage) {
          case 'recover':
            f.uploads.beforeRecover = failOnce;
          case 'read terminal':
            f.uploads.beforeRead = failOnce;
          case 'settings':
            f.beforeSettings = failOnce;
          case 'clear':
            f.beforePersist = () {
              if (f.implicit['webdavSyncOperation'] == null) failOnce();
            };
          case 'ack':
            f.uploads.beforeAck = failOnce;
        }
        final first = await f.controller.uploadData();
        expect(first.error, isTrue);
        final failure = first.failure! as DataSyncFailure;
        expect(
          failure.failures.any(
            (e) => identical(e.error, error) && identical(e.stack, stack),
          ),
          isTrue,
        );
        expect((await f.controller.downloadData()).success, isTrue);
        expect(f.transfer.uploads, 0);
        expect(f.uploads.recoveries, stage == 'recover' ? 2 : 1);
        expect(f.durable['webdavSyncOperation'], isNull);
      },
    );
  }

  test(
    'missing terminal evidence never authorizes marker clear or ack',
    () async {
      final f = _Fixture()..install();
      addTearDown(f.dispose);
      f.uploads.writeTerminal = false;
      expect((await f.controller.uploadData()).error, isTrue);
      expect(f.durable['webdavSyncOperation'], isNotNull);
      expect(f.uploads.acks, isEmpty);
    },
  );

  test(
    'restart after marker removal only acknowledges terminal orphan receipts',
    () async {
      final f = _Fixture()..install();
      addTearDown(f.dispose);
      f.uploads.beforeAck = () => throw StateError('ack interrupted');
      expect((await f.controller.uploadData()).error, isTrue);
      expect(f.durable['webdavSyncOperation'], isNull);
      f.uploads.beforeAck = null;
      f.rebuild();
      f.controller.start();
      await pumpEventQueue();
      expect(f.uploads.terminals, isEmpty);
      expect(f.uploads.recoveries, 1);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.transfer.uploads, 0);
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'disposed flush' : 'exit'} waits for admitted upload recovery and ack',
      () async {
        final f = _Fixture()..install();
        addTearDown(f.dispose);
        final recovering = Completer<void>();
        final acknowledging = Completer<void>();
        f.uploads.beforeRecover = () => recovering.future;
        f.uploads.beforeAck = () => acknowledging.future;
        final attempt = f.controller.uploadData();
        await pumpEventQueue();
        var closed = false;
        final Future<void> closing;
        if (dispose) {
          f.controller.dispose();
          closing = f.controller.flushPersistence().then((_) => closed = true);
        } else {
          closing = f.controller.prepareForExit().then((release) {
            closed = true;
            release();
          });
        }
        await pumpEventQueue();
        expect(closed, isFalse);
        recovering.complete();
        await pumpEventQueue();
        expect(closed, isFalse);
        expect(f.durable['webdavSyncOperation'], isNull);
        acknowledging.complete();
        expect((await attempt).success, isTrue);
        await closing;
        expect(closed, isTrue);
        expect(f.uploads.acks, ['operation']);
      },
    );
  }
}

const _old = ['https://old.test', 'old', 'password'];
const _draft = ['https://new.test', 'new', 'password'];
Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class _Fixture {
  final settings = <String, dynamic>{
    'webdav': List<String>.of(_old),
    'disableSyncFields': '',
  };
  Map<String, dynamic> implicit = {
    'webdavSyncMode': 'manual',
    'webdavSyncPending': false,
  };
  Map<String, dynamic> durable = {};
  final uploads = _Uploads();
  final transfer = _Transfer();
  DataSyncController? _controller;
  FutureOr<void> Function()? beforeSettings;
  FutureOr<void> Function()? beforePersist;

  _Fixture() {
    durable = _copy(implicit);
    uploads.afterAck = () => expect(durable['webdavSyncOperation'], isNull);
  }

  SyncPreferenceStore get preferences => SyncPreferenceStore(
    readSetting: (key) => settings[key],
    writeSetting: (key, value) => settings[key] = value,
    implicitData: () => implicit,
  );

  DataSyncController get controller => _controller ??= DataSyncController(
    preferences: preferences,
    transfer: () => transfer,
    uploadRecovery: uploads,
    saveSettings: () async {
      await beforeSettings?.call();
    },
    persistImplicit: () async {
      await beforePersist?.call();
      durable = _copy(implicit);
    },
    observeChanges: (_) => () {},
  );

  void install({int version = 3, SyncPreferenceCheckpoint? previous}) {
    implicit['webdavSyncOperation'] = DataSyncOperation(
      version: version,
      id: 'operation',
      direction: DataSyncDirection.upload,
      connection: _draft,
      excludedFields: 'local-only',
      mode: DataSyncMode.manual.name,
      intervalMinutes: 30,
      pendingBefore: false,
      generation: 0,
      commitState: DataSyncCommitState.recoveryRequired,
      followUpComplete: false,
      configurationChange: previous != null,
      previousConfiguration: previous,
    ).toJson();
    durable = _copy(implicit);
  }

  void rebuild() {
    dispose();
    implicit = _copy(durable);
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
  }
}

class _Uploads implements DataSyncUploadRecovery {
  final terminals = <String, DataSyncCommitState>{};
  final acks = <String>[];
  final endpoints = <List<String>>[];
  int recoveries = 0;
  bool writeTerminal = true;
  DataSyncCommitState recoveredState = DataSyncCommitState.applied;
  FutureOr<void> Function()? beforeRecover;
  FutureOr<void> Function()? beforeRead;
  FutureOr<void> Function()? beforeAck;
  void Function()? afterAck;

  @override
  Future<DataSyncCommitState> recoverUpload(
    WebDavEndpoint connection, {
    required String syncOperationId,
    required RequestScope scope,
  }) async {
    recoveries++;
    endpoints.add([connection.url, connection.user, connection.password]);
    await beforeRecover?.call();
    if (writeTerminal) terminals[syncOperationId] = recoveredState;
    return recoveredState;
  }

  @override
  Future<DataSyncCommitState?> readTerminalUploadReceipt(
    WebDavEndpoint connection,
    String syncOperationId,
  ) async {
    await beforeRead?.call();
    return terminals[syncOperationId];
  }

  @override
  Future<List<String>> listTerminalUploadOperations() async =>
      terminals.keys.toList();
  @override
  Future<void> acknowledgeUpload(String syncOperationId) async {
    await beforeAck?.call();
    afterAck?.call();
    acks.add(syncOperationId);
    terminals.remove(syncOperationId);
  }
}

class _Transfer implements DataSyncTransfer {
  int uploads = 0;
  int downloads = 0;
  String? operationId;
  Future<void> Function()? onUpload;
  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
    required RequestScope scope,
    String? syncOperationId,
  }) async {
    uploads++;
    operationId = syncOperationId;
    await onUpload?.call();
  }

  @override
  Future<bool> download(
    WebDavEndpoint connection, {
    required RequestScope scope,
    bool force = false,
    String? syncOperationId,
    void Function(void Function())? publishImported,
  }) async {
    downloads++;
    return false;
  }
}
