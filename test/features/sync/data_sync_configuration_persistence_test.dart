import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import '../../support/data_sync_fixture.dart';

class _Fixture extends SyncTestFixture {
  _Fixture(
    Map<String, dynamic> settings,
    Map<String, dynamic> implicit, {
    required Future<void> Function() settingsSave,
    required FutureOr<void> Function() implicitSave,
  }) : super(
         preferences: SyncPreferenceStore(
           readSetting: (key) => settings[key],
           writeSetting: (key, value) => settings[key] = value,
           implicitData: () => implicit,
         ),
         saveSettings: settingsSave,
         persistImplicit: implicitSave,
       );
}

void main() {
  late Map<String, dynamic> settings;
  late Map<String, dynamic> implicit;
  setUp(() {
    settings = {
      'webdav': ['https://old.example/dav', 'u', 'p'],
      'disableSyncFields': 'old',
    };
    implicit = {'webdavSyncMode': 'manual', 'unknown': 7};
  });

  for (final failRollback in [false, true]) {
    test(
      'no-op draft save failure remains failed after rollback: $failRollback',
      () async {
        var saves = 0;
        var downloads = 0;
        var reject = true;
        final fixture = _Fixture(
          settings,
          implicit,
          settingsSave: () async {
            saves++;
            if (reject && (saves == 1 || failRollback)) {
              throw StateError('settings unavailable $saves');
            }
          },
          implicitSave: () {},
        );
        addTearDown(fixture.disposeController);
        fixture.transfer.onDownload = () async {
          downloads++;
          return const Res(false);
        };
        final first = await fixture.controller.configure(
          config: ['https://new.example/dav', 'u', 'p'],
          excludedFields: '',
          syncMode: DataSyncMode.realtime,
          minutes: 15,
          initialUpload: false,
        );
        expect(first.errorMessage, contains('settings unavailable 1'));
        expect(fixture.controller.statusSnapshot.lastError, first.errorMessage);
        expect(settings['webdav'], ['https://old.example/dav', 'u', 'p']);
        if (failRollback) {
          expect(implicit['webdavSyncOperation'], isNotNull);
          final retried = await fixture.controller.uploadData();
          expect(retried.errorMessage, contains('settings unavailable'));
          expect(implicit['webdavSyncOperation'], isNotNull);
          reject = false;
          await fixture.controller.uploadData();
        }
        expect(downloads, 1);
        expect(implicit['webdavSyncOperation'], isNull);
      },
    );
  }

  test(
    'same draft cleanup failure result remains visible after receipt removal',
    () async {
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () async {},
        implicitSave: () {},
      );
      addTearDown(fixture.disposeController);
      var resumed = 0;
      fixture.transfer.onDownload = () async => throw DataSyncTransferFailure(
        commitState: DataSyncCommitState.notApplied,
        failures: [
          (
            stage: 'file cleanup',
            error: StateError('before import failure'),
            stack: StackTrace.current,
          ),
        ],
        resume: (_) async {
          resumed++;
          return DataSyncCommitState.notApplied;
        },
      );
      Future<Res<bool>> configure() => fixture.controller.configure(
        config: ['https://new.example/dav', 'u', 'p'],
        excludedFields: '',
        syncMode: DataSyncMode.realtime,
        minutes: 15,
        initialUpload: false,
      );
      expect((await configure()).error, isTrue);
      final result = await configure();
      expect(result.error, isTrue);
      expect(resumed, 1);
      expect(implicit['webdavSyncOperation'], isNull);
      expect(fixture.controller.statusSnapshot.lastError, result.errorMessage);
    },
  );

  test(
    'configuration success waits for implicit and ordinary settings',
    () async {
      final implicitGate = Completer<void>();
      final settingsGate = Completer<void>();
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () => settingsGate.future,
        implicitSave: () => implicitGate.future,
      );
      addTearDown(fixture.disposeController);
      var completed = false;
      final saving = fixture.controller
          .configure(
            config: ['https://new.example/dav', 'u', 'p'],
            excludedFields: 'new',
            syncMode: DataSyncMode.manual,
            minutes: 30,
            initialUpload: false,
          )
          .then((result) {
            completed = true;
            return result;
          });
      await pumpEventQueue();
      settingsGate.complete();
      await pumpEventQueue();
      expect(completed, isFalse);
      final busy = await fixture.controller.configure(
        config: [],
        excludedFields: '',
        syncMode: DataSyncMode.manual,
        minutes: 30,
        initialUpload: false,
      );
      expect(busy.error, isTrue);
      implicitGate.complete();
      expect((await saving).success, isTrue);
      expect(settings['disableSyncFields'], 'new');
      expect(implicit['unknown'], 7);
    },
  );

  test(
    'failed write joins the other file before rollback and awaits restoration',
    () async {
      final settingsCommit = Completer<void>();
      final implicitRollback = Completer<void>();
      var implicitWrites = 0;
      var settingsWrites = 0;
      final fixture = _Fixture(
        settings,
        implicit,
        implicitSave: () {
          implicitWrites++;
          return implicitWrites == 1
              ? Future.error(StateError('implicit failed'))
              : implicitRollback.future;
        },
        settingsSave: () {
          settingsWrites++;
          return settingsWrites == 1 ? settingsCommit.future : Future.value();
        },
      );
      addTearDown(fixture.disposeController);
      var completed = false;
      final saving = fixture.controller
          .configure(
            config: [],
            excludedFields: 'new',
            syncMode: DataSyncMode.manual,
            minutes: 30,
            initialUpload: false,
          )
          .then((result) {
            completed = true;
            return result;
          });
      await pumpEventQueue();
      expect(implicitWrites, 1);
      expect(settingsWrites, 1);
      expect(completed, isFalse);
      settingsCommit.complete();
      await pumpEventQueue();
      expect(implicitWrites, 2);
      expect(settingsWrites, 2);
      expect(completed, isFalse);
      expect(settings['disableSyncFields'], 'old');
      expect(implicit['unknown'], 7);
      implicitRollback.complete();
      expect((await saving).errorMessage, contains('implicit failed'));
    },
  );

  test(
    'rollback implicit failure still restores ordinary settings and reports both errors',
    () async {
      var settingsWrites = 0;
      var implicitWrites = 0;
      final fixture = _Fixture(
        settings,
        implicit,
        implicitSave: () {
          implicitWrites++;
          if (implicitWrites == 1) return;
          throw StateError('rollback implicit failed');
        },
        settingsSave: () async {
          settingsWrites++;
          if (settingsWrites == 1) throw StateError('settings commit failed');
        },
      );
      addTearDown(fixture.disposeController);
      final result = await fixture.controller.configure(
        config: [],
        excludedFields: 'new',
        syncMode: DataSyncMode.manual,
        minutes: 30,
        initialUpload: false,
      );
      expect(settingsWrites, 2);
      expect(implicitWrites, 2);
      expect(result.errorMessage, contains('settings commit failed'));
      expect(result.errorMessage, contains('rollback implicit failed'));
      expect(settings['disableSyncFields'], 'old');
      expect(implicit, {'webdavSyncMode': 'manual', 'unknown': 7});
    },
  );

  test(
    'commit and rollback retain all four original save errors and stacks',
    () async {
      final errors = List.generate(4, (index) => StateError('save $index'));
      final stacks = List.generate(
        4,
        (index) => StackTrace.fromString('stack $index'),
      );
      var implicitWrites = 0;
      var settingsWrites = 0;
      final fixture = _Fixture(
        settings,
        implicit,
        implicitSave: () {
          final index = implicitWrites++ * 2;
          Error.throwWithStackTrace(errors[index], stacks[index]);
        },
        settingsSave: () async {
          final index = settingsWrites++ * 2 + 1;
          Error.throwWithStackTrace(errors[index], stacks[index]);
        },
      );
      addTearDown(fixture.disposeController);
      final result = await fixture.controller.configure(
        config: [],
        excludedFields: 'new',
        syncMode: DataSyncMode.manual,
        minutes: 30,
        initialUpload: false,
      );
      final failure = result.failure! as DataSyncFailure;
      expect(failure.commitState, DataSyncCommitState.notApplied);
      expect(failure.failures.map((f) => f.error), unorderedEquals(errors));
      expect(failure.failures.map((f) => f.stack), unorderedEquals(stacks));
      expect(settings['webdav'], ['https://old.example/dav', 'u', 'p']);
    },
  );

  test(
    'applied draft with failed follow-up stays on the new endpoint and resumes once',
    () async {
      implicit['webdavSyncPending'] = true;
      var downloads = 0;
      var uploads = 0;
      var resumed = 0;
      final cleanup = StateError('import backup cleanup');
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () async {},
        implicitSave: () {},
      );
      addTearDown(fixture.disposeController);
      fixture.transfer.onDownload = () async {
        downloads++;
        throw DataSyncTransferFailure(
          commitState: DataSyncCommitState.applied,
          failures: [
            (
              stage: 'backup cleanup',
              error: cleanup,
              stack: StackTrace.current,
            ),
          ],
          resume: (_) async {
            resumed++;
            return DataSyncCommitState.applied;
          },
        );
      };
      fixture.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      Future<Res<bool>> configure() => fixture.controller.configure(
        config: ['https://new.example/dav', 'n', 'p'],
        excludedFields: 'new',
        syncMode: DataSyncMode.realtime,
        minutes: 15,
        initialUpload: false,
      );
      final first = await configure();
      expect(
        (first.failure as DataSyncFailure).commitState,
        DataSyncCommitState.applied,
      );
      expect(settings['webdav'], ['https://new.example/dav', 'n', 'p']);
      expect(implicit['webdavSyncPending'], isFalse);
      expect(
        (implicit['webdavSyncOperation'] as Map)['followUpComplete'],
        isFalse,
      );
      expect((await configure()).success, isTrue);
      expect(downloads, 1);
      expect(uploads, 0);
      expect(resumed, 1);
      expect(implicit['webdavSyncOperation'], isNull);
    },
  );

  test(
    'applied draft settings failure keeps receipt until settings retry succeeds',
    () async {
      var rejectSettings = true;
      var downloads = 0;
      final savedMarkers = <Object?>[];
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () async {
          expect(implicit['webdavSyncOperation'], isNotNull);
          if (rejectSettings) throw StateError('settings unavailable');
        },
        implicitSave: () {
          savedMarkers.add(implicit['webdavSyncOperation']);
        },
      );
      addTearDown(fixture.disposeController);
      fixture.transfer.onDownload = () async {
        downloads++;
        return const Res(true);
      };
      Future<Res<bool>> configure() => fixture.controller.configure(
        config: ['https://new.example/dav', 'n', 'p'],
        excludedFields: '',
        syncMode: DataSyncMode.scheduled,
        minutes: 60,
        initialUpload: false,
      );
      expect(
        (await configure()).errorMessage,
        contains('settings unavailable'),
      );
      expect(savedMarkers, isNot(contains(null)));
      expect(settings['webdav'], ['https://new.example/dav', 'n', 'p']);
      expect(implicit['webdavSyncMode'], 'scheduled');
      rejectSettings = false;
      expect((await configure()).success, isTrue);
      expect(savedMarkers.last, isNull);
      expect(downloads, 1);
    },
  );

  test(
    'failed draft rollback retains receipt and retries only the old configuration',
    () async {
      var rejectRollback = true;
      var uploads = 0;
      var downloads = 0;
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () async {
          expect(implicit['webdavSyncOperation'], isNotNull);
          if (rejectRollback) throw StateError('rollback settings unavailable');
        },
        implicitSave: () {},
      );
      addTearDown(fixture.disposeController);
      fixture.transfer.onDownload = () async {
        downloads++;
        return const Res.error('download failed');
      };
      fixture.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      final result = await fixture.controller.configure(
        config: ['https://new.example/dav', 'n', 'p'],
        excludedFields: '',
        syncMode: DataSyncMode.realtime,
        minutes: 15,
        initialUpload: false,
      );
      expect(result.errorMessage, contains('download failed'));
      expect(result.errorMessage, contains('rollback settings unavailable'));
      expect(settings['webdav'], ['https://old.example/dav', 'u', 'p']);
      expect(implicit['webdavSyncOperation'], isNotNull);
      rejectRollback = false;
      // The first subsequent request completes the failed operation's rollback.
      expect(
        (await fixture.controller.uploadData()).errorMessage,
        contains('download failed'),
      );
      expect(uploads, 0);
      expect(downloads, 1);
      expect(implicit['webdavSyncOperation'], isNull);
      expect((await fixture.controller.uploadData()).success, isTrue);
      expect(uploads, 1);
    },
  );

  test(
    'unresolved draft outcome retains its endpoint and blocks queued work',
    () async {
      var uploads = 0;
      final fixture = _Fixture(
        settings,
        implicit,
        settingsSave: () async {},
        implicitSave: () {},
      );
      addTearDown(fixture.disposeController);
      fixture.transfer.onDownload = () async => throw DataSyncFailure(
        commitState: DataSyncCommitState.recoveryRequired,
        recoveryPath: 'recoverable-import',
        failures: [
          (
            stage: 'restore database',
            error: StateError('restore failed'),
            stack: StackTrace.current,
          ),
        ],
      );
      fixture.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      final result = await fixture.controller.configure(
        config: ['https://new.example/dav', 'n', 'p'],
        excludedFields: '',
        syncMode: DataSyncMode.realtime,
        minutes: 15,
        initialUpload: false,
      );
      expect(
        (result.failure as DataSyncFailure).commitState,
        DataSyncCommitState.recoveryRequired,
      );
      expect(settings['webdav'], ['https://new.example/dav', 'n', 'p']);
      expect((await fixture.controller.uploadData()).error, isTrue);
      expect(uploads, 0);
      expect(
        (implicit['webdavSyncOperation'] as Map)['recoveryPath'],
        'recoverable-import',
      );
    },
  );
}
