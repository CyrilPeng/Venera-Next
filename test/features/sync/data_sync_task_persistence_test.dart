import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import '../../support/data_sync_fixture.dart';

void main() {
  late Map<String, dynamic> implicit;
  SyncTestFixture fixture(FutureOr<void> Function() persist) {
    final value = SyncTestFixture(
      preferences: SyncPreferenceStore(
        readSetting: (key) =>
            key == 'webdav' ? ['https://example.test/dav', 'u', 'p'] : null,
        writeSetting: (_, _) {},
        implicitData: () => implicit,
      ),
      persistImplicit: persist,
    );
    addTearDown(value.disposeController);
    return value;
  }

  setUp(
    () => implicit = {'webdavSyncMode': 'manual', 'webdavSyncPending': true},
  );

  test(
    'initial persistence failure prevents transfer and clears busy state',
    () async {
      var uploads = 0;
      final f = fixture(() async => throw StateError('initial save'));
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

  test(
    'terminal persistence failure retains pending changes and retry can finish',
    () async {
      var writes = 0;
      var uploads = 0;
      final f = fixture(() async {
        if (++writes == 2) throw StateError('final save');
      });
      f.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      final result = await f.controller.uploadData();
      expect(result.errorMessage, contains('final save'));
      expect(f.controller.hasPendingChanges, isTrue);
      expect(f.controller.isUploading, isFalse);
      expect((await f.controller.uploadData()).success, isTrue);
      expect(f.controller.hasPendingChanges, isFalse);
      expect(uploads, 2);
    },
  );

  test(
    'terminal save holds the active task and prevents queued transfer overlap',
    () async {
      final gate = Completer<void>();
      var writes = 0;
      var uploads = 0;
      final f = fixture(() {
        if (++writes == 2) return gate.future;
      });
      f.transfer.onUpload = () async {
        uploads++;
        return const Res(true);
      };
      final first = f.controller.uploadData();
      await pumpEventQueue();
      final second = f.controller.uploadData();
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
    var writes = 0;
    final f = fixture(() async {
      if (++writes == 2) throw StateError('disk');
    });
    f.transfer.onUpload = () async => const Res.error('network');
    final result = await f.controller.uploadData();
    expect(result.errorMessage, contains('network'));
    expect(result.errorMessage, contains('disk'));
    expect(f.controller.lastError, result.errorMessage);
    expect(f.controller.hasPendingChanges, isTrue);
  });

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
