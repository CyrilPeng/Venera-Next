import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import 'package:venera_next/features/sync/data_sync_content.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_operation.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';

void main() {
  late Directory root;
  setUp(
    () => root = Directory.systemTemp.createTempSync('sync-controller-owner-'),
  );
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'a contender cannot subscribe, mark pending, or persist before takeover',
    () async {
      final first = _Fixture(root.path);
      final second = _Fixture(root.path);
      first.controller.start();
      first.controller.stop();
      second.controller.start();
      expect(first.listeners, 1);
      expect(second.listeners, 0);
      second.controller.onDataChanged();
      expect(second.controller.hasPendingChanges, isFalse);
      expect(second.saves, 0);
      await first.controller.closeAndWait();
      second.controller.start();
      expect(second.listeners, 1);
      second.controller.onDataChanged();
      expect(second.controller.hasPendingChanges, isTrue);
      await second.controller.closeAndWait();
      expect(first.listeners, 0);
      expect(second.listeners, 0);
    },
  );

  test(
    'disposing an unacquired contender cannot overwrite owned state',
    () async {
      final first = _Fixture(root.path);
      final second = _Fixture(root.path);
      first.controller.start();
      second.controller.start();
      await second.controller.closeAndWait();
      expect(second.saves, 0);
      await first.controller.closeAndWait();
    },
  );

  test(
    'shared close waits for recovery and final persistence before releasing',
    () async {
      final fixture = _Fixture(root.path);
      final recovery = fixture.content.recoveryGate = Completer<void>();
      final persistence = fixture.saveGate = Completer<void>();
      final next = SqliteDataSyncOwnership(() => root.path);
      fixture.controller.start();
      await fixture.content.recoveryEntered.future;
      var closed = false;
      final closing = fixture.controller.closeAndWait();
      expect(fixture.controller.closeAndWait(), same(closing));
      closing.then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(fixture.listeners, 0);
      expect(next.acquire, throwsA(isA<SqliteException>()));
      recovery.complete();
      await fixture.saveEntered.future;
      expect(next.acquire, throwsA(isA<SqliteException>()));
      persistence.complete();
      await closing;
      next.acquire();
      next.release();
      expect(fixture.content.closes, 1);
    },
  );

  test(
    'failed content close retains owner and retries without replaying saves',
    () async {
      final fixture = _Fixture(root.path);
      fixture.content.closeFailures = 1;
      fixture.controller.start();
      final next = SqliteDataSyncOwnership(() => root.path);
      await expectLater(fixture.controller.closeAndWait(), throwsStateError);
      final saved = fixture.saves;
      expect(next.acquire, throwsA(isA<SqliteException>()));
      await fixture.controller.closeAndWait();
      expect(fixture.saves, saved);
      expect(fixture.content.closes, 2);
      next.acquire();
      next.release();
    },
  );

  test(
    'failed final persistence keeps owner until the save retry settles',
    () async {
      final fixture = _Fixture(root.path)..saveFailures = 1;
      fixture.controller.start();
      final next = SqliteDataSyncOwnership(() => root.path);
      await expectLater(fixture.controller.closeAndWait(), throwsStateError);
      expect(fixture.content.closes, 0);
      expect(next.acquire, throwsA(isA<SqliteException>()));
      await fixture.controller.closeAndWait();
      expect(fixture.saves, 2);
      next.acquire();
      next.release();
    },
  );

  test(
    'a release that throws after unlocking cannot replay writes on retry',
    () async {
      final ownership = _ReportedRelease(
        SqliteDataSyncOwnership(() => root.path),
      );
      final first = _Fixture(root.path, ownership: ownership);
      first.controller.start();
      await expectLater(first.controller.closeAndWait(), throwsStateError);
      final saved = first.saves;
      final second = _Fixture(root.path);
      second.controller.start();
      expect(second.listeners, 1);
      await first.controller.closeAndWait();
      expect(first.saves, saved);
      second.controller.onDataChanged();
      expect(second.controller.hasPendingChanges, isTrue);
      await second.controller.closeAndWait();
    },
  );

  test(
    'recovery diagnostic is reported after closing and does not retain a dead owner',
    () async {
      final fixture = _Fixture(root.path);
      fixture.content.recoveryError = StateError('broken candidate');
      fixture.controller.start();
      await pumpEventQueue();
      await expectLater(
        fixture.controller.closeAndWait(),
        throwsA(isA<DataSyncFailure>()),
      );
      final saved = fixture.saves;
      final next = SqliteDataSyncOwnership(() => root.path)..acquire();
      await expectLater(
        fixture.controller.closeAndWait(),
        throwsA(isA<DataSyncFailure>()),
      );
      expect(fixture.saves, saved);
      next.release();
    },
  );
}

class _Fixture {
  _Fixture(String path, {DataSyncOwnership? ownership}) {
    controller = DataSyncController(
      preferences: SyncPreferenceStore(
        readSetting: (key) =>
            key == 'webdav' ? ['https://example.com', '', ''] : '',
        writeSetting: (_, _) {},
        implicitData: () => implicit,
      ),
      transfer: () => throw StateError('No transfer expected'),
      saveSettings: () async {},
      persistImplicit: () async {
        saves++;
        if (!saveEntered.isCompleted) saveEntered.complete();
        await saveGate?.future;
        if (saveFailures > 0) {
          saveFailures--;
          throw StateError('save failed');
        }
      },
      observeChanges: (_) {
        listeners++;
        return () => listeners--;
      },
      ownership: ownership ?? SqliteDataSyncOwnership(() => path),
      content: content,
    );
  }
  final implicit = <String, dynamic>{'webdavSyncMode': 'manual'};
  final content = _Content();
  final saveEntered = Completer<void>();
  Completer<void>? saveGate;
  int saveFailures = 0;
  int saves = 0;
  int listeners = 0;
  late final DataSyncController controller;
}

class _Content implements DataSyncContent {
  final recoveryEntered = Completer<void>();
  Completer<void>? recoveryGate;
  Object? recoveryError;
  int closes = 0;
  int closeFailures = 0;
  @override
  Future<bool> recover(DataSyncOperation? operation) async {
    if (!recoveryEntered.isCompleted) recoveryEntered.complete();
    await recoveryGate?.future;
    if (recoveryError case final error?) throw error;
    return false;
  }

  @override
  Future<void> close() async {
    closes++;
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('close failed');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReportedRelease implements DataSyncOwnership {
  _ReportedRelease(this.inner);
  final DataSyncOwnership inner;
  bool failed = false;
  @override
  void acquire() => inner.acquire();
  @override
  void release() {
    inner.release();
    if (!failed) {
      failed = true;
      throw StateError('release reported failure');
    }
  }
}
