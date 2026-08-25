import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test('does not configure a comic source list by default', () {
    expect(appdata.settings['comicSourceListUrl'], isEmpty);
  });

  test('reader settings resolve from global, device, then comic scope', () {
    final previousDeviceId = appdata.settings['deviceId'];
    final previousDeviceSettings = appdata.settings['deviceSpecificSettings'];
    final previousComicSettings = appdata.settings['comicSpecificSettings'];
    final previousPageNumber = appdata.settings['showPageNumberInReader'];
    final previousClockInfo =
        appdata.settings['enableClockAndBatteryInfoInReader'];

    try {
      appdata.settings['deviceId'] = 'reader-settings-test-device';
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['showPageNumberInReader'] = true;
      appdata.settings['enableClockAndBatteryInfoInReader'] = true;

      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('showPageNumberInReader', false);
      appdata.settings.setDeviceReaderSetting(
        'enableClockAndBatteryInfoInReader',
        false,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isFalse,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );

      appdata.settings.setEnabledComicSpecificSettings(
        'comic-id',
        'source-key',
        true,
      );
      appdata.settings.setReaderSetting(
        'comic-id',
        'source-key',
        'showPageNumberInReader',
        true,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isTrue,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );
    } finally {
      appdata.settings['deviceId'] = previousDeviceId;
      appdata.settings['deviceSpecificSettings'] = previousDeviceSettings;
      appdata.settings['comicSpecificSettings'] = previousComicSettings;
      appdata.settings['showPageNumberInReader'] = previousPageNumber;
      appdata.settings['enableClockAndBatteryInfoInReader'] = previousClockInfo;
    }
  });

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

  test('saveData keeps the previous appdata snapshot as backup', () async {
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
    appdata.settings['proxy'] = 'first';
    appdata.searchHistory = ['first'];
    await appdata.saveData(false);

    appdata.settings['proxy'] = 'second';
    appdata.searchHistory = ['second'];
    await appdata.saveData(false);

    final appDataFile = File('${dataDir.path}/appdata.json');
    final appData = jsonDecode(appDataFile.readAsStringSync());
    final backupData = jsonDecode(
      File('${appDataFile.path}.bak').readAsStringSync(),
    );

    expect(appData['settings']['proxy'], 'second');
    expect(appData['searchHistory'], ['second']);
    expect(backupData['settings']['proxy'], 'first');
    expect(backupData['searchHistory'], ['first']);
  });

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
    'does not overwrite current files while completing a partial migration',
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

  test(
    'migrates missing data even when the current directory is not empty',
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
      File(p.join(currentDir.path, 'logs.txt')).writeAsStringSync('new log');

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
      expect(
        File(p.join(currentDir.path, 'logs.txt')).readAsStringSync(),
        'new log',
      );
    },
  );

  test(
    'migrates data from the original Windows application identity',
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
        p.join(baseDir.path, 'com.github.wgh136', 'venera'),
      )..createSync(recursive: true);
      File(p.join(legacyDir.path, 'appdata.json')).writeAsStringSync('legacy');

      final currentDir = Directory(
        p.join(baseDir.path, 'com.github.cyrilpeng', 'VeneraNext'),
      )..createSync(recursive: true);

      await App.migrateLegacyWindowsPathForTesting(currentDir.path);

      expect(
        File(p.join(currentDir.path, 'appdata.json')).readAsStringSync(),
        'legacy',
      );
    },
  );

  test(
    'recovers appdata from backup without deleting the invalid file',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-load-',
      );
      addTearDown(() {
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      final appDataFile = File(p.join(dataDir.path, 'appdata.json'))
        ..writeAsStringSync('{invalid');
      File('${appDataFile.path}.bak').writeAsStringSync(
        jsonEncode({
          'settings': {'proxy': 'http://127.0.0.1:7890'},
          'searchHistory': ['restored'],
        }),
      );

      await appdata.loadDataForTesting(dataDir.path);

      expect(appdata.settings['proxy'], 'http://127.0.0.1:7890');
      expect(appdata.searchHistory, ['restored']);
      expect(jsonDecode(appDataFile.readAsStringSync()), isA<Map>());
      expect(
        dataDir.listSync().whereType<File>().any(
          (file) => p.basename(file.path).startsWith('appdata.json.corrupt-'),
        ),
        isTrue,
      );
    },
  );
}
