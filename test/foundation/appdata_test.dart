import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

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

  test(
    'migrates legacy Windows company directory when the new directory is empty',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'CyrilPeng_venera-next', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');
      final legacySubDir = Directory(p.join(legacyDir.path, 'comic_source'))
        ..createSync();
      File(
        p.join(legacySubDir.path, 'source.json'),
      ).writeAsStringSync('source');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.cyrilpeng', 'VeneraNext'),
      )..createSync(recursive: true);

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
      expect(
        File(
          p.join(currentDir.path, 'comic_source', 'source.json'),
        ).readAsStringSync(),
        'source',
      );
    },
  );

  test(
    'does not migrate legacy Windows data into a non-empty directory',
    () async {
      final baseDir = Directory.systemTemp.createTempSync(
        'venera-appdata-migration-',
      );
      addTearDown(() {
        if (baseDir.existsSync()) {
          baseDir.deleteSync(recursive: true);
        }
      });

      final legacyDir = Directory(
        p.join(baseDir.path, 'CyrilPeng_venera-next', 'VeneraNext'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.cyrilpeng', 'VeneraNext'),
      )..createSync(recursive: true);
      File(
        p.join(currentDir.path, 'appdata.json'),
      ).writeAsStringSync('current');

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'current',
      );
    },
  );
}
