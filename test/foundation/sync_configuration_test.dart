import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/sync_configuration.dart';
import 'package:venera_next/foundation/sync_preference_store.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test(
    'sync configuration distinguishes empty and malformed legacy connections',
    () {
      expect(SyncConnection.parse([])!.isEmpty, isTrue);
      for (final invalid in [
        null,
        '',
        ['url'],
        ['url', 'user', 1],
      ]) {
        expect(SyncConnection.parse(invalid), isNull);
      }
      final raw = [' url ', ' user ', ' password '];
      final parsed = SyncConnection.parse(raw)!;
      raw[0] = 'changed';
      expect(parsed.url, ' url ');
      expect(parsed.password, ' password ');
      expect(parsed.isEmpty, isFalse);
    },
  );

  test(
    'sync mode fallback and interval validation preserve legacy semantics',
    () {
      final implicit = <String, Object?>{'webdavAutoSync': true};
      SyncConfiguration read() =>
          SyncConfiguration.read((_) => null, (key) => implicit[key]);
      expect(read().mode, DataSyncMode.realtime);
      implicit['webdavSyncMode'] = 'manual';
      expect(read().mode, DataSyncMode.manual);
      implicit['webdavSyncMode'] = 'unknown';
      expect(read().mode, DataSyncMode.realtime);
      for (final invalid in [null, '60', 60.0, 0, 7]) {
        implicit['webdavSyncIntervalMinutes'] = invalid;
        expect(read().intervalMinutes, 30);
      }
      implicit['webdavSyncIntervalMinutes'] = 60;
      expect(read().intervalMinutes, 60);
      expect(read().excludedFields, isEmpty);
    },
  );

  test(
    'configuration rollback preserves raw legacy values and absent keys',
    () {
      final store = SyncPreferenceStore(appdata);
      final original = store.capture();
      addTearDown(() => store.restore(original));
      appdata.settings['webdav'] = ['legacy'];
      appdata.settings['disableSyncFields'] = ' readerMode,customField ';
      appdata.implicitData.remove('webdavSyncMode');
      appdata.implicitData['webdavAutoSync'] = true;
      appdata.implicitData['webdavSyncIntervalMinutes'] = 'legacy';
      final checkpoint = store.capture();
      final draft = ['https://example.test/', 'user', 'password'];
      store.applyDraft(draft, 'language');
      draft[0] = 'changed';
      expect(store.configuration.connection!.url, 'https://example.test/');
      store.setSchedule(DataSyncMode.scheduled, 60);
      store.pending = true;
      store.lastAttempt = 123;
      store.restore(checkpoint);
      expect(appdata.settings['webdav'], ['legacy']);
      expect(appdata.settings['disableSyncFields'], ' readerMode,customField ');
      expect(appdata.implicitData.containsKey('webdavSyncMode'), isFalse);
      expect(appdata.implicitData['webdavSyncIntervalMinutes'], 'legacy');
      expect(store.configuration.mode, DataSyncMode.realtime);
    },
  );
}
