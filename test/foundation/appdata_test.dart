import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';

void main() {
  test(
    'saveData queues concurrent writes and keeps the latest snapshot',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-appdata-');
      addTearDown(() {
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = 'proxy';
      appdata.settings['proxy'] = 'first';
      appdata.searchHistory = ['first'];

      final firstSave = appdata.saveData(false);
      appdata.settings['proxy'] = 'second';
      appdata.searchHistory = ['second'];
      final secondSave = appdata.saveData(false);

      await Future.wait([firstSave, secondSave]);

      final appDataFile = File('${dataDir.path}/appdata.json');
      final syncDataFile = File('${dataDir.path}/syncdata.json');
      final appData = jsonDecode(appDataFile.readAsStringSync());
      final syncData = jsonDecode(syncDataFile.readAsStringSync());

      expect(appData['settings']['proxy'], 'second');
      expect(appData['searchHistory'], ['second']);
      expect(syncData['settings'].containsKey('proxy'), isFalse);
    },
  );
}
