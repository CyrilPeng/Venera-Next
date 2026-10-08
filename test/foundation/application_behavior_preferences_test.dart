import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_updates.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = App.cachePath = Directory.systemTemp.path;

  test(
    'retention rounds supported old values without clamping to editor bounds',
    () {
      final preference = AppPreferences.historyRetentionDays;
      for (final (raw, expected) in <(Object?, int)>[
        (0, 0),
        (0.49, 0),
        (0.5, 1),
        (7.49, 7),
        (7.5, 8),
        (182, 182),
        (365, 365),
        (100000000, 100000000),
        (-10, 0),
        (100000001, 0),
        (1e100, 0),
        (double.nan, 0),
        (double.infinity, 0),
        (double.negativeInfinity, 0),
        ('7', 0),
        (null, 0),
        (false, 0),
      ]) {
        expect(preference.normalize(raw), expected, reason: '$raw');
      }
      expect(applicationPreferenceDefaults['historyRetentionDays'], 0);
      expect(applicationPreferenceDefaults['language'], 'system');
      expect(applicationPreferenceDefaults['checkUpdateOnStart'], false);
    },
  );

  test('startup update preference rejects malformed truthy values', () {
    final before = appdata.settings['checkUpdateOnStart'];
    addTearDown(() => appdata.settings['checkUpdateOnStart'] = before);
    final check = createStartupUpdateCheck(
      sources: SourceUpdateService(),
      checkApplication: (_) async {},
    );
    for (final value in <Object?>[null, 'true', 1, [], {}]) {
      appdata.settings['checkUpdateOnStart'] = value;
      expect(check.applicationCheckEnabled(), isFalse);
      expect(appdata.settings['checkUpdateOnStart'], same(value));
    }
  });

  test(
    'invalid retention keeps history and permits database initialization',
    () async {
      final path = App.dataPath;
      final cache = App.cachePath;
      final before = appdata.settings['historyRetentionDays'];
      final directory = Directory.systemTemp.createTempSync(
        'retention-preference-',
      );
      App.dataPath = App.cachePath = directory.path;
      var manager = HistoryManager.create();
      try {
        appdata.settings['historyRetentionDays'] = 0;
        await manager.init();
        await manager.addHistory(
          History.fromMap({
            'id': 'old',
            'type': ComicType.local.value,
            'time': DateTime(2000).millisecondsSinceEpoch,
            'title': 'Old history',
            'subtitle': '',
            'cover': '',
            'ep': 1,
            'page': 1,
            'readEpisode': ['1'],
            'max_page': 1,
          }),
        );
        await manager.waitForAsyncWrites();
        manager.close();
        for (final value in <Object?>[
          'bad',
          true,
          [],
          {},
          double.nan,
          double.infinity,
        ]) {
          appdata.settings['historyRetentionDays'] = value;
          manager = HistoryManager.create();
          await manager.init();
          expect(manager.find('old', ComicType.local), isNotNull);
          expect(appdata.settings['historyRetentionDays'], same(value));
          await manager.waitForAsyncWrites();
          manager.close();
        }
      } finally {
        await manager.waitForAsyncWrites();
        manager.close();
        appdata.settings['historyRetentionDays'] = before;
        App.dataPath = path;
        App.cachePath = cache;
        directory.deleteSync(recursive: true);
      }
    },
  );
}
