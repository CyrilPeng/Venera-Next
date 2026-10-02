import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync_controller.dart';
import 'package:venera_next/features/sync/data_sync_transfer.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  test(
    'independent controllers isolate preferences, pending changes and subscriptions',
    () {
      final first = _Fixture();
      final second = _Fixture();
      addTearDown(first.controller.dispose);
      addTearDown(second.controller.dispose);
      first.controller.start();
      first.controller.start();
      second.controller.start();
      expect(first.listeners, hasLength(1));
      first.changed();
      expect(first.controller.hasPendingChanges, isTrue);
      expect(second.controller.hasPendingChanges, isFalse);
      first.controller.dispose();
      expect(first.listeners, isEmpty);
      second.changed();
      expect(second.controller.hasPendingChanges, isTrue);
      expect(second.listeners, hasLength(1));
    },
  );

  test('stop retains observation while dispose releases it', () {
    final fixture = _Fixture();
    fixture.controller.start();
    fixture.controller.stop();
    fixture.changed();
    expect(fixture.controller.hasPendingChanges, isTrue);
    fixture.controller.start();
    expect(fixture.listeners, hasLength(1));
    fixture.controller.dispose();
    expect(fixture.listeners, isEmpty);
    expect(fixture.unsubscribeCount, 1);
  });

  test(
    'injected clock and timer schedule only the owning controller',
    () async {
      final first = _Fixture();
      final second = _Fixture();
      addTearDown(first.controller.dispose);
      addTearDown(second.controller.dispose);
      for (final fixture in [first, second]) {
        fixture.preferences.setSchedule(DataSyncMode.scheduled, 15);
        fixture.preferences.lastAttempt = fixture.now.millisecondsSinceEpoch;
        fixture.controller.start();
      }
      expect(first.timers.single.duration, const Duration(minutes: 15));
      first.now = first.now.add(const Duration(minutes: 5));
      first.controller.checkForAutomaticSync();
      expect(first.timers.first.isActive, isFalse);
      expect(first.timers.last.duration, const Duration(minutes: 10));
      first.now = first.now.add(const Duration(minutes: 10));
      first.timers.last.fire();
      await first.controller.waitForDownload();
      expect(first.transfer.downloads, 1);
      expect(second.transfer.downloads, 0);
      expect(second.timers.single.isActive, isTrue);
      first.controller.stop();
      expect(first.timers.every((timer) => !timer.isActive), isTrue);
    },
  );

  test('failed subscription can be retried without leaving started state', () {
    final fixture = _Fixture()..failSubscription = true;
    expect(fixture.controller.start, throwsStateError);
    expect(fixture.listeners, isEmpty);
    fixture.failSubscription = false;
    fixture.controller.start();
    expect(fixture.listeners, hasLength(1));
    fixture.controller.dispose();
    expect(fixture.unsubscribeCount, 1);
  });

  test(
    'failed draft transfer restores only its own preference checkpoint',
    () async {
      final first = _Fixture();
      final second = _Fixture();
      addTearDown(first.controller.dispose);
      addTearDown(second.controller.dispose);
      first.transfer.uploadError = StateError('denied');
      final result = await first.controller.configure(
        config: ['https://new.example.com', 'new-user', 'new-pass'],
        excludedFields: 'new-field',
        syncMode: DataSyncMode.realtime,
        minutes: 15,
        initialUpload: true,
      );
      expect(result.error, isTrue);
      expect(first.settings['webdav'], ['https://example.com', '', '']);
      expect(first.controller.currentMode, DataSyncMode.manual);
      expect(first.settings['disableSyncFields'], 'old-field');
      expect(first.saveCount, 1);
      expect(second.saveCount, 0);
      expect(second.controller.lastError, isNull);
    },
  );

  test(
    'replacing implicit settings storage is observed without recreating controller',
    () {
      final fixture = _Fixture();
      addTearDown(fixture.controller.dispose);
      fixture.implicit = {
        'webdavSyncMode': 'scheduled',
        'webdavSyncIntervalMinutes': 60,
        'webdavSyncPending': true,
      };
      expect(fixture.controller.currentMode, DataSyncMode.scheduled);
      expect(fixture.controller.currentIntervalMinutes, 60);
      expect(fixture.controller.hasPendingChanges, isTrue);
    },
  );
}

class _Fixture {
  final settings = <String, Object?>{
    'webdav': ['https://example.com', '', ''],
    'disableSyncFields': 'old-field',
  };
  Map<String, dynamic> implicit = {'webdavSyncMode': 'manual'};
  final listeners = <void Function()>{};
  final timers = <_Timer>[];
  final transfer = _Transfer();
  DateTime now = DateTime.utc(2026, 1, 1);
  bool failSubscription = false;
  int saveCount = 0;
  int unsubscribeCount = 0;
  late final preferences = SyncPreferenceStore(
    readSetting: (key) => settings[key],
    writeSetting: (key, value) => settings[key] = value,
    implicitData: () => implicit,
  );
  late final controller = DataSyncController(
    preferences: preferences,
    transfer: () => transfer,
    saveSettings: () async {
      saveCount++;
    },
    persistImplicit: () {},
    observeChanges: (changed) {
      if (failSubscription) throw StateError('subscription failed');
      listeners.add(changed);
      return () {
        unsubscribeCount++;
        listeners.remove(changed);
      };
    },
    now: () => now,
    createTimer: (duration, callback) {
      final timer = _Timer(duration, callback);
      timers.add(timer);
      return timer;
    },
  );

  void changed() {
    for (final listener in listeners.toList()) {
      listener();
    }
  }
}

class _Transfer implements DataSyncTransfer {
  int downloads = 0;
  Object? uploadError;
  @override
  Future<bool> download(WebDavEndpoint connection) async {
    downloads++;
    return false;
  }

  @override
  Future<void> upload(
    WebDavEndpoint connection, {
    required bool excludeFields,
  }) async {
    final error = uploadError;
    if (error != null) throw error;
  }
}

class _Timer implements Timer {
  _Timer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}
