import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
}
