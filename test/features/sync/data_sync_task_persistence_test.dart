import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import '../../support/data_sync_fixture.dart';

void main() {
  late Map<String, dynamic> implicit;
  SyncTestFixture fixture(
    FutureOr<void> Function() persist, {
    Map<String, dynamic>? storage,
  }) {
    final data = storage ?? implicit;
    final value = SyncTestFixture(
      preferences: SyncPreferenceStore(
        readSetting: (key) =>
            key == 'webdav' ? ['https://example.test/dav', 'u', 'p'] : null,
        writeSetting: (_, _) {},
        implicitData: () => data,
      ),
      persistImplicit: persist,
    );
    addTearDown(value.disposeController);
    return value;
  }

  setUp(
    () => implicit = {'webdavSyncMode': 'manual', 'webdavSyncPending': true},
  );

  DataSyncOperation? marker() => implicit['webdavSyncOperation'] == null
      ? null
      : DataSyncOperation.fromJson(implicit['webdavSyncOperation']);

  test(
    'initial persistence failure prevents transfer and clears busy state',
    () async {
      var uploads = 0;
      final f = fixture(() async {
        expect(marker()!.commitState, DataSyncCommitState.notApplied);
        expect(marker()!.followUpComplete, isFalse);
        throw StateError('initial save');
      });
      f.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      final result = await f.controller.uploadData();
      expect(result.errorMessage, contains('initial save'));
      expect(uploads, 0);
      expect(f.controller.isUploading, isFalse);
      expect(f.controller.hasPendingChanges, isTrue);
    },
  );

  for (final clearReceipt in [false, true]) {
    test(
      'applied upload retries only ${clearReceipt ? 'receipt removal' : 'receipt save'}',
      () async {
        var shouldFail = true;
        var uploads = 0;
        final diskError = StateError('final save');
        final diskStack = StackTrace.fromString('final save stack');
        final f = fixture(() async {
          final operation = marker();
          final phaseMatches = clearReceipt
              ? operation == null
              : operation?.commitState == DataSyncCommitState.applied &&
                    operation!.followUpComplete;
          if (shouldFail && phaseMatches) {
            shouldFail = false;
            Error.throwWithStackTrace(diskError, diskStack);
          }
        });
        f.transfer.onUpload = () async {
          uploads++;
          return const Res(true);
        };
        final result = await f.controller.uploadData();
        expect(result.errorMessage, contains('final save'));
        final failure = result.failure! as DataSyncFailure;
        expect(failure.commitState, DataSyncCommitState.applied);
        expect(failure.failures, [
          (
            stage: clearReceipt ? 'clear sync receipt' : 'save sync receipt',
            error: diskError,
            stack: diskStack,
          ),
        ]);
        expect(f.controller.hasPendingChanges, isFalse);
        expect(marker()!.commitState, DataSyncCommitState.applied);
        expect(marker()!.followUpComplete, isTrue);
        expect(f.controller.isUploading, isFalse);
        expect((await f.controller.uploadData()).success, isTrue);
        expect(f.controller.hasPendingChanges, isFalse);
        expect(marker(), isNull);
        expect(uploads, 1);
      },
    );
  }

  test(
    'terminal save holds the active task and prevents queued transfer overlap',
    () async {
      final gate = Completer<void>();
      final transferGate = Completer<Res<bool>>();
      var gateReceipt = true;
      var uploads = 0;
      final f = fixture(() {
        final operation = marker();
        if (gateReceipt &&
            operation?.commitState == DataSyncCommitState.applied &&
            operation!.followUpComplete) {
          gateReceipt = false;
          return gate.future;
        }
      });
      f.transfer.onUpload = () async {
        uploads++;
        return uploads == 1 ? transferGate.future : const Res(true);
      };
      final first = f.controller.uploadData();
      await pumpEventQueue();
      final second = f.controller.uploadData();
      transferGate.complete(const Res(true));
      await pumpEventQueue();
      var waiting = true;
      final wait = f.controller.waitForUpload().then((_) => waiting = false);
      expect(f.controller.isUploading, isTrue);
      expect(uploads, 1);
      expect(waiting, isTrue);
      gate.complete();
      expect((await first).success, isTrue);
      expect((await second).success, isTrue);
      await wait;
      expect(uploads, 2);
      expect(waiting, isFalse);
    },
  );

  test('network and final persistence errors are both reported', () async {
    final networkError = StateError('network');
    final networkStack = StackTrace.fromString('network stack');
    final diskError = StateError('disk');
    final diskStack = StackTrace.fromString('disk stack');
    final f = fixture(() async {
      final operation = marker();
      if (operation?.commitState == DataSyncCommitState.notApplied &&
          operation!.followUpComplete) {
        Error.throwWithStackTrace(diskError, diskStack);
      }
    });
    f.transfer.onUpload = () async =>
        Error.throwWithStackTrace(networkError, networkStack);
    final result = await f.controller.uploadData();
    expect(result.errorMessage, contains('network'));
    expect(result.errorMessage, contains('disk'));
    expect(f.controller.lastError, result.errorMessage);
    expect(f.controller.hasPendingChanges, isTrue);
    final failure = result.failure! as DataSyncFailure;
    expect(failure.commitState, DataSyncCommitState.notApplied);
    expect(failure.failures, [
      (stage: 'transfer', error: networkError, stack: networkStack),
      (stage: 'save sync receipt', error: diskError, stack: diskStack),
    ]);
  });

  test(
    'applied download resumes follow-up without another import or upload',
    () async {
      final f = fixture(() {});
      var downloads = 0;
      var imports = 0;
      var uploads = 0;
      var notifications = 0;
      var timestampWrites = 0;
      var cleanups = 0;
      final notificationError = StateError('notification failed');
      final notificationStack = StackTrace.fromString('notification stack');
      f.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      f.transfer.onDownload = () async {
        downloads++;
        imports++;
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.applied,
          failures: [
            (
              stage: 'publish import',
              error: notificationError,
              stack: notificationStack,
            ),
          ],
          resume: (_) async {
            notifications++;
            timestampWrites++;
            cleanups++;
            return DataSyncCommitState.applied;
          },
        );
      };
      final failed = await f.controller.downloadData();
      expect(failed.error, isTrue);
      expect((failed.failure! as DataSyncFailure).failures, [
        (
          stage: 'publish import',
          error: notificationError,
          stack: notificationStack,
        ),
      ]);
      expect(f.controller.hasPendingChanges, isFalse);
      expect(marker()!.direction, DataSyncDirection.download);
      expect(marker()!.commitState, DataSyncCommitState.applied);
      expect(marker()!.followUpComplete, isFalse);
      expect((await f.controller.uploadData()).success, isTrue);
      expect([downloads, imports, uploads], [1, 1, 0]);
      expect([notifications, timestampWrites, cleanups], [1, 1, 1]);
      expect(marker(), isNull);
    },
  );

  test(
    'successful resume is not repeated after receipt persistence fails',
    () async {
      var failReceipt = true;
      var downloads = 0;
      var resumes = 0;
      final f = fixture(() async {
        final operation = marker();
        if (failReceipt &&
            operation?.commitState == DataSyncCommitState.applied &&
            operation!.followUpComplete) {
          failReceipt = false;
          throw StateError('resumed receipt save');
        }
      });
      f.transfer.onDownload = () async {
        downloads++;
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.applied,
          failures: [
            (
              stage: 'cleanup',
              error: StateError('cleanup failed'),
              stack: StackTrace.current,
            ),
          ],
          resume: (_) async {
            resumes++;
            return DataSyncCommitState.applied;
          },
        );
      };
      expect((await f.controller.downloadData()).error, isTrue);
      expect(marker()!.followUpComplete, isFalse);
      final resumed = await f.controller.downloadData();
      expect(resumed.errorMessage, contains('resumed receipt save'));
      expect(marker()!.followUpComplete, isTrue);
      expect([downloads, resumes], [1, 1]);
      expect((await f.controller.downloadData()).success, isTrue);
      expect([downloads, resumes], [1, 1]);
      expect(marker(), isNull);
    },
  );

  for (final initialDownload in [false, true]) {
    test(
      'concurrent same and opposite direction requests share one ${initialDownload ? 'download' : 'upload'} resume',
      () async {
        final resumeGate = Completer<void>();
        var uploads = 0;
        var downloads = 0;
        var resumes = 0;
        final f = fixture(() {});
        Future<Res<bool>> failAfterApplied() async =>
            throw DataSyncTransferFailure(
              commitState: DataSyncCommitState.applied,
              failures: [
                (
                  stage: 'cleanup',
                  error: StateError('cleanup failed'),
                  stack: StackTrace.current,
                ),
              ],
              resume: (_) async {
                resumes++;
                await resumeGate.future;
                return DataSyncCommitState.applied;
              },
            );
        f.transfer.onUpload = () {
          uploads++;
          return failAfterApplied();
        };
        f.transfer.onDownload = () {
          downloads++;
          return failAfterApplied();
        };
        final sync = f.controller;
        final initial = await (initialDownload
            ? sync.downloadData()
            : sync.uploadData());
        expect(initial.error, isTrue);
        final resumed = initialDownload
            ? sync.downloadData()
            : sync.uploadData();
        await pumpEventQueue();
        var completed = 0;
        final joined =
            [
                  resumed,
                  sync.uploadData(),
                  sync.downloadData(),
                  initialDownload ? sync.downloadData() : sync.uploadData(),
                ]
                .map(
                  (future) => future.then((result) {
                    completed++;
                    return result;
                  }),
                )
                .toList();
        await pumpEventQueue();
        expect(resumes, 1);
        expect(completed, 0);
        expect([uploads, downloads], initialDownload ? [0, 1] : [1, 0]);
        expect(sync.isDownloading, initialDownload);
        expect(sync.isUploading, !initialDownload);
        resumeGate.complete();
        expect(
          (await Future.wait(joined)).every((result) => result.success),
          isTrue,
        );
        expect(resumes, 1);
        expect([uploads, downloads], initialDownload ? [0, 1] : [1, 0]);
        expect(marker(), isNull);
      },
    );
  }

  test(
    'realtime uploads the new generation after its queued request finishes the old receipt',
    () async {
      implicit['webdavSyncMode'] = 'realtime';
      final oldTransferGate = Completer<void>();
      final resumeGate = Completer<void>();
      final newTransferGate = Completer<Res<bool>>();
      final uploadGenerations = <int>[];
      var resumes = 0;
      var downloads = 0;
      final f = fixture(() {});
      f.transfer.onUpload = () async {
        uploadGenerations.add(marker()!.generation);
        if (uploadGenerations.length > 1) return newTransferGate.future;
        await oldTransferGate.future;
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.applied,
          failures: [
            (
              stage: 'cleanup',
              error: StateError('old cleanup failed'),
              stack: StackTrace.current,
            ),
          ],
          resume: (_) async {
            resumes++;
            await resumeGate.future;
            return DataSyncCommitState.applied;
          },
        );
      };
      f.transfer.onDownload = () async {
        downloads++;
        return const Res(false);
      };
      final sync = f.controller..start();
      await pumpEventQueue();
      expect(uploadGenerations, [0]);
      sync.onDataChanged();
      oldTransferGate.complete();
      await pumpEventQueue();
      expect(resumes, 1);
      expect(uploadGenerations, [0]);
      expect(sync.hasPendingChanges, isTrue);
      expect(marker()!.generation, 0);
      expect(marker()!.followUpComplete, isFalse);
      resumeGate.complete();
      await pumpEventQueue();
      expect(uploadGenerations, [0, 1]);
      expect(marker()!.generation, 1);
      expect(sync.hasPendingChanges, isTrue);
      expect(sync.isUploading, isTrue);
      newTransferGate.complete(const Res(true));
      await sync.waitForUpload();
      await pumpEventQueue();
      expect(uploadGenerations, [0, 1]);
      expect(resumes, 1);
      expect(downloads, 0);
      expect(sync.hasPendingChanges, isFalse);
      expect(sync.isUploading, isFalse);
      expect(marker(), isNull);
    },
  );

  for (final duringTransfer in [false, true]) {
    test(
      'new edits ${duringTransfer ? 'during transfer' : 'after failed receipt'} survive finalization retry',
      () async {
        var failReceipt = true;
        var uploads = 0;
        final f = fixture(() async {
          final operation = marker();
          if (failReceipt &&
              operation?.commitState == DataSyncCommitState.applied &&
              operation!.followUpComplete) {
            failReceipt = false;
            throw StateError('receipt save');
          }
        });
        f.transfer.onUpload = () async {
          uploads++;
          if (duringTransfer) f.controller.onDataChanged();
          return const Res(true);
        };
        expect((await f.controller.uploadData()).error, isTrue);
        if (!duringTransfer) f.controller.onDataChanged();
        await pumpEventQueue();
        expect(f.controller.hasPendingChanges, isTrue);
        expect((await f.controller.uploadData()).success, isTrue);
        expect(f.controller.hasPendingChanges, isTrue);
        expect(uploads, 1);
        expect(marker(), isNull);
      },
    );
  }

  test(
    'persisted unfinished marker blocks a recreated controller without replaying transfer',
    () async {
      String? persisted;
      final first = fixture(() => persisted = jsonEncode(implicit));
      var resumes = 0;
      first.transfer.onDownload = () async => throw DataSyncTransferFailure(
        commitState: DataSyncCommitState.applied,
        recoveryPath: 'retained/download-backup',
        failures: [
          (
            stage: 'cleanup',
            error: StateError('cleanup failed'),
            stack: StackTrace.current,
          ),
        ],
        resume: (_) async {
          resumes++;
          return DataSyncCommitState.applied;
        },
      );
      expect((await first.controller.downloadData()).error, isTrue);
      first.disposeController();
      final restored = jsonDecode(persisted!) as Map<String, dynamic>;
      expect(identical(restored, implicit), isFalse);
      restored['webdavSyncMode'] = 'realtime';
      var transfers = 0;
      var writes = 0;
      final recreated = fixture(() => writes++, storage: restored);
      recreated.transfer.onUpload = recreated.transfer.onDownload = () async {
        transfers++;
        return const Res(true);
      };
      final before = jsonEncode(restored['webdavSyncOperation']);
      recreated.controller.start();
      recreated.controller.checkForAutomaticSync();
      await pumpEventQueue();
      for (final result in [
        await recreated.controller.uploadData(),
        await recreated.controller.downloadData(),
        await recreated.controller.configure(
          config: ['https://other.example.test', 'u', 'p'],
          excludedFields: '',
          syncMode: DataSyncMode.manual,
          minutes: 30,
          initialUpload: true,
        ),
      ]) {
        expect(result.error, isTrue);
        final failure = result.failure! as DataSyncFailure;
        expect(failure.commitState, DataSyncCommitState.recoveryRequired);
        expect(failure.recoveryPath, 'retained/download-backup');
        expect(failure.failures.single.stage, 'recover sync operation');
      }
      expect([transfers, resumes, writes], [0, 0, 0]);
      expect(jsonEncode(restored['webdavSyncOperation']), before);
    },
  );

  test(
    'corrupt durable marker blocks manual and automatic transfers and stays intact',
    () async {
      final corrupt = {'version': 1, 'id': 'incomplete'};
      implicit['webdavSyncOperation'] = corrupt;
      implicit['webdavSyncMode'] = 'scheduled';
      var transfers = 0;
      var writes = 0;
      final f = fixture(() => writes++);
      f.transfer.onUpload = f.transfer.onDownload = () async {
        transfers++;
        return const Res(true);
      };
      f.controller.start();
      f.controller.checkForAutomaticSync();
      await pumpEventQueue();
      for (final result in [
        await f.controller.uploadData(),
        await f.controller.downloadData(),
      ]) {
        expect(result.error, isTrue);
        final failure = result.failure! as DataSyncFailure;
        expect(failure.commitState, DataSyncCommitState.recoveryRequired);
        expect(failure.failures.single.stage, 'read sync operation');
        expect(failure.failures.single.error, isFormatException);
      }
      expect([transfers, writes], [0, 0]);
      expect(implicit['webdavSyncOperation'], same(corrupt));
    },
  );

  test(
    'queued transfer cannot dispatch after active task requires recovery',
    () async {
      final gate = Completer<void>();
      var uploads = 0;
      var downloads = 0;
      final recoveryError = StateError('uncertain replacement');
      final recoveryStack = StackTrace.fromString('replacement stack');
      final f = fixture(() {});
      f.transfer.onUpload = () async {
        uploads++;
        await gate.future;
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.recoveryRequired,
          recoveryPath: 'retained/originals',
          failures: [
            (
              stage: 'restore import',
              error: recoveryError,
              stack: recoveryStack,
            ),
          ],
        );
      };
      f.transfer.onDownload = () async {
        downloads++;
        return const Res(true);
      };
      final active = f.controller.uploadData();
      await pumpEventQueue();
      final queued = f.controller.downloadData();
      gate.complete();
      for (final result in [await active, await queued]) {
        expect(result.error, isTrue);
        final failure = result.failure! as DataSyncFailure;
        expect(failure.commitState, DataSyncCommitState.recoveryRequired);
        expect(failure.recoveryPath, 'retained/originals');
        expect(failure.failures, [
          (stage: 'restore import', error: recoveryError, stack: recoveryStack),
        ]);
      }
      expect([uploads, downloads], [1, 0]);
      expect(f.controller.hasPendingChanges, isTrue);
      expect(marker()!.commitState, DataSyncCommitState.recoveryRequired);
      expect(marker()!.followUpComplete, isFalse);
    },
  );

  test('dispose during initial persistence prevents a late transfer', () async {
    final gate = Completer<void>();
    var uploads = 0;
    final f = fixture(() => gate.future);
    f.transfer.onUpload = () async {
      uploads++;
      return const Res(true);
    };
    var notifiedBusy = false;
    f.controller.addListener(() {
      if (f.controller.isUploading) notifiedBusy = true;
    });
    final result = f.controller.uploadData();
    expect(notifiedBusy, isTrue);
    f.controller.dispose();
    gate.complete();
    expect((await result).error, isTrue);
    expect(uploads, 0);
  });

  test(
    'background pending save errors are observed without losing local changes',
    () async {
      implicit['webdavSyncPending'] = false;
      final f = fixture(() async => throw StateError('pending save'));
      f.controller.onDataChanged();
      await pumpEventQueue();
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.controller.lastError, contains('pending save'));
    },
  );
  test(
    'flush after disposal waits for already accepted background writes',
    () async {
      implicit['webdavSyncPending'] = false;
      final oldSave = Completer<void>();
      final latestSave = Completer<void>();
      var calls = 0;
      final f = fixture(
        () => ++calls == 1 ? oldSave.future : latestSave.future,
      );
      f.controller.onDataChanged();
      f.controller.dispose();
      var done = false;
      final flush = f.controller.flushPersistence().then((_) => done = true);
      latestSave.complete();
      await pumpEventQueue();
      expect(done, isFalse);
      oldSave.complete();
      await flush;
      expect(done, isTrue);
    },
  );

  test(
    'flush includes writes accepted while its latest snapshot is pending',
    () async {
      implicit['webdavSyncPending'] = false;
      final first = Completer<void>();
      final late = Completer<void>();
      var calls = 0;
      final f = fixture(() => ++calls == 1 ? first.future : late.future);
      var done = false;
      final flush = f.controller.flushPersistence().then((_) => done = true);
      f.controller.onDataChanged();
      first.complete();
      await pumpEventQueue();
      expect(done, isFalse);
      late.complete();
      await flush;
      expect(done, isTrue);
    },
  );

  test(
    'failed flush propagates and a later flush retries latest state',
    () async {
      var calls = 0;
      final f = fixture(() async {
        if (++calls == 1) throw StateError('disk unavailable');
      });
      await expectLater(f.controller.flushPersistence(), throwsStateError);
      await f.controller.flushPersistence();
      expect(calls, 2);
    },
  );
}
