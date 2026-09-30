import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/sync/data_sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

const config = ['https://example.com/dav/VeneraNext', 'user', 'password'];

void main() {
  void scheduleTest(
    String name,
    Future<void> Function(_ScheduleClock, _Calls) body,
  ) {
    test(name, () async {
      final clock = _ScheduleClock();
      final directory = Directory.systemTemp.createTempSync('sync-schedule-');
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'],
      );
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      DataSync.resetForTesting();
      DataSync.debugDisableWindowCloseHandler = true;
      DataSync.debugNow = clock.now;
      App.dataPath = directory.path;
      Log.isMuted = true;
      appdata.settings['webdav'] = config;
      appdata.implicitData.clear();
      appdata.implicitData.addAll({
        'webdavSyncMode': 'scheduled',
        'webdavSyncLastAttempt': clock.now().millisecondsSinceEpoch,
      });
      final calls = _Calls();
      calls.install();
      try {
        await runZoned(
          () => body(clock, calls),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (duration == Duration.zero) {
                return parent.createTimer(zone, duration, callback);
              }
              return clock.createTimer(duration, zone.bindCallback(callback));
            },
          ),
        );
      } finally {
        DataSync.resetForTesting();
        await appdata.saveData(false);
        directory.deleteSync(recursive: true);
        appdata.implicitData.clear();
        appdata.implicitData.addAll(previousImplicit);
        previousSettings.forEach((key, value) => appdata.settings[key] = value);
        Log.clear();
        Log.isMuted = false;
      }
    });
  }

  scheduleTest('legacy preference migration and invalid interval fallback', (
    clock,
    calls,
  ) async {
    appdata.implicitData.remove('webdavSyncMode');
    expect(DataSync.mode, DataSyncMode.manual);
    appdata.implicitData['webdavAutoSync'] = true;
    expect(DataSync.mode, DataSyncMode.realtime);
    appdata.implicitData['webdavSyncMode'] = 'scheduled';
    expect(DataSync.mode, DataSyncMode.scheduled);
    appdata.implicitData['webdavSyncIntervalMinutes'] = -1;
    expect(DataSync.intervalMinutes, 30);
    appdata.implicitData['webdavSyncIntervalMinutes'] = 60;
    expect(DataSync.intervalMinutes, 60);
  });

  scheduleTest(
    'changes are batched until due; idle intervals only check downloads',
    (clock, calls) async {
      final sync = DataSync();
      for (var i = 0; i < 10; i++) {
        sync.onDataChanged();
      }
      await clock.elapse(const Duration(minutes: 29));
      sync.checkForAutomaticSync(); // Resume cannot bypass the interval.
      expect(calls.uploads, 0);
      expect(calls.downloads, 0);
      await clock.elapse(const Duration(minutes: 1));
      expect(calls.uploads, 1);
      expect(calls.downloads, 0);
      expect(sync.hasPendingChanges, isFalse);
      await clock.elapse(const Duration(minutes: 30));
      expect(calls.uploads, 1);
      expect(calls.downloads, 1);
    },
  );

  scheduleTest('pending changes and deadline survive restart', (
    clock,
    calls,
  ) async {
    DataSync().onDataChanged();
    await appdata.saveData(false);
    final saved =
        jsonDecode(File('${App.dataPath}/implicitData.json').readAsStringSync())
            as Map;
    expect(saved['webdavSyncPending'], isTrue);
    DataSync.resetForTesting();
    await clock.elapse(const Duration(minutes: 10));
    DataSync.debugDisableWindowCloseHandler = true;
    DataSync.debugNow = clock.now;
    calls.install();
    appdata.implicitData.clear();
    appdata.implicitData.addAll(Map<String, dynamic>.from(saved));
    DataSync();
    expect(calls.uploads, 0);
    DataSync.resetForTesting();
    await clock.elapse(const Duration(minutes: 25));
    DataSync.debugDisableWindowCloseHandler = true;
    DataSync.debugNow = clock.now;
    calls.install();
    DataSync();
    await clock.elapse();
    expect(calls.uploads, 1);
    expect(calls.downloads, 0);
  });

  scheduleTest('failed attempt keeps pending edits and waits before retry', (
    clock,
    calls,
  ) async {
    DataSync.debugUploadOverride = () async {
      calls.uploads++;
      return const Res.error('offline');
    };
    final sync = DataSync()..onDataChanged();
    await clock.elapse(const Duration(minutes: 30));
    expect(sync.lastError, 'offline');
    expect(sync.hasPendingChanges, isTrue);
    sync.checkForAutomaticSync();
    await clock.elapse(const Duration(minutes: 29));
    expect(calls.uploads, 1);
    calls.install();
    await clock.elapse(const Duration(minutes: 1));
    expect(calls.uploads, 2);
    expect(sync.hasPendingChanges, isFalse);
  });

  scheduleTest(
    'edits during upload remain pending without an immediate second upload',
    (clock, calls) async {
      final upload = Completer<Res<bool>>();
      DataSync.debugUploadOverride = () {
        calls.uploads++;
        return upload.future;
      };
      final sync = DataSync()..onDataChanged();
      await clock.elapse(const Duration(minutes: 30));
      sync.onDataChanged();
      sync.checkForAutomaticSync();
      upload.complete(const Res(true));
      await clock.elapse();
      expect(sync.hasPendingChanges, isTrue);
      expect(calls.uploads, 1);
      calls.install();
      await clock.elapse(const Duration(minutes: 30));
      expect(calls.uploads, 2);
      expect(sync.hasPendingChanges, isFalse);
    },
  );

  scheduleTest('download import notifications do not schedule an upload', (
    clock,
    calls,
  ) async {
    final sync = DataSync();
    DataSync.debugDownloadOverride = () async {
      calls.downloads++;
      sync.onDataChanged();
      return const Res(true);
    };
    await clock.elapse(const Duration(minutes: 60));
    expect(calls.downloads, 1);
    expect(sync.hasPendingChanges, isFalse);
    expect(calls.uploads, 0);
  });

  scheduleTest('download without a newer snapshot keeps local edits pending', (
    clock,
    calls,
  ) async {
    final sync = DataSync()..onDataChanged();
    await sync.downloadData();
    expect(calls.downloads, 1);
    expect(sync.hasPendingChanges, isTrue);
    await clock.elapse(const Duration(minutes: 30));
    expect(calls.uploads, 1);
    expect(sync.hasPendingChanges, isFalse);
  });

  scheduleTest(
    'manual sync works immediately and postpones the next scheduled check',
    (clock, calls) async {
      final sync = DataSync()..onDataChanged();
      await clock.elapse(const Duration(minutes: 20));
      await sync.uploadData();
      await clock.elapse(const Duration(minutes: 10));
      sync.checkForAutomaticSync();
      expect(calls.uploads, 1);
      expect(calls.downloads, 0);
      await clock.elapse(const Duration(minutes: 20));
      expect(calls.downloads, 1);
    },
  );

  scheduleTest(
    'manual mode has no automatic transfer; realtime preserves immediate uploads',
    (clock, calls) async {
      appdata.implicitData['webdavSyncMode'] = 'manual';
      final sync = DataSync()..onDataChanged();
      sync.checkForAutomaticSync();
      await clock.elapse(const Duration(hours: 2));
      expect(calls.uploads + calls.downloads, 0);
      expect(sync.statusSnapshot.shouldShow, isTrue);
      await sync.uploadData();
      expect(calls.uploads, 1);
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      sync.onDataChanged();
      await clock.elapse();
      expect(calls.uploads, 2);
    },
  );

  scheduleTest(
    'configuration rollback retains endpoint, mode, fields and schedule',
    (clock, calls) async {
      final sync = DataSync()..onDataChanged();
      appdata.settings['disableSyncFields'] = 'readerMode';
      final previous = Map<String, dynamic>.from(appdata.implicitData);
      DataSync.debugUploadOverride = () async => const Res.error('denied');
      final result = await sync.configure(
        config: ['https://example.com/new', 'new-user', 'new-password'],
        excludedFields: 'language',
        syncMode: DataSyncMode.realtime,
        minutes: 60,
        initialUpload: true,
      );
      expect(result.error, isTrue);
      expect(appdata.settings['webdav'], config);
      expect(appdata.settings['disableSyncFields'], 'readerMode');
      expect(appdata.implicitData, previous);
      calls.install();
      await clock.elapse(const Duration(minutes: 30));
      expect(calls.uploads, 1);
    },
  );

  scheduleTest(
    'failed configuration keeps local edits made during its initial upload',
    (clock, calls) async {
      final sync = DataSync();
      expect(sync.hasPendingChanges, isFalse);
      DataSync.debugUploadOverride = () async {
        sync.onDataChanged();
        return const Res.error('denied');
      };
      final result = await sync.configure(
        config: ['https://example.test/new', 'user', 'password'],
        excludedFields: 'language',
        syncMode: DataSyncMode.realtime,
        minutes: 60,
        initialUpload: true,
      );
      expect(result.error, isTrue);
      expect(appdata.settings['webdav'], config);
      expect(sync.hasPendingChanges, isTrue);
      expect(DataSync.mode, DataSyncMode.scheduled);
    },
  );

  scheduleTest(
    'saving manual mode cancels timer, and changing interval reschedules it',
    (clock, calls) async {
      final sync = DataSync();
      await sync.configure(
        config: config,
        excludedFields: '',
        syncMode: DataSyncMode.manual,
        minutes: 15,
        initialUpload: true,
      );
      sync.onDataChanged();
      await clock.elapse(const Duration(hours: 1));
      expect(calls.uploads + calls.downloads, 0);
      await sync.configure(
        config: config,
        excludedFields: '',
        syncMode: DataSyncMode.scheduled,
        minutes: 15,
        initialUpload: true,
      );
      sync.checkForAutomaticSync();
      expect(calls.uploads, 1);
      await clock.elapse(const Duration(minutes: 14));
      expect(calls.downloads, 0);
      await clock.elapse(const Duration(minutes: 1));
      expect(calls.downloads, 1);
      await sync.configure(
        config: [],
        excludedFields: '',
        syncMode: DataSyncMode.scheduled,
        minutes: 15,
        initialUpload: true,
      );
      await clock.elapse(const Duration(hours: 1));
      expect(sync.isEnabled, isFalse);
      expect(calls.downloads, 1);
    },
  );

  scheduleTest('future timestamp recovers and dispose cancels automatic work', (
    clock,
    calls,
  ) async {
    appdata.implicitData['webdavSyncLastAttempt'] = clock
        .now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch;
    final sync = DataSync();
    await clock.elapse();
    expect(calls.downloads, 1);
    sync.dispose();
    DataSync.instance = null;
    await clock.elapse(const Duration(hours: 2));
    expect(calls.downloads, 1);
  });
}

class _ScheduleClock {
  DateTime current = DateTime(2026, 9, 27);
  final timers = <_ScheduledTimer>[];
  DateTime now() => current;

  Timer createTimer(Duration duration, void Function() callback) {
    final timer = _ScheduledTimer(current.add(duration), callback);
    timers.add(timer);
    return timer;
  }

  Future<void> elapse([Duration duration = Duration.zero]) async {
    current = current.add(duration);
    for (final timer in timers.toList()) {
      if (timer.isActive && !timer.due.isAfter(current)) timer.fire();
    }
    await pumpEventQueue();
  }
}

class _ScheduledTimer implements Timer {
  _ScheduledTimer(this.due, this.callback);
  final DateTime due;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    isActive = false;
    tick++;
    callback();
  }
}

class _Calls {
  int uploads = 0;
  int downloads = 0;
  void install() {
    DataSync.debugUploadOverride = () async {
      uploads++;
      return const Res(true);
    };
    DataSync.debugDownloadOverride = () async {
      downloads++;
      return const Res(true);
    };
  }
}
