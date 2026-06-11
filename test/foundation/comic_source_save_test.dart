import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  setUp(() {
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    appdata.implicitData['webdavAutoSync'] = false;
  });

  tearDown(() {
    appdata.implicitData['webdavAutoSync'] = false;
    DataSync.resetForTesting();
  });

  test(
    'saveData coalesces concurrent writes and keeps latest source data',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-comic-source-',
      );
      addTearDown(() {
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });
      App.dataPath = dataDir.path;

      var uploadCount = 0;
      DataSync.debugUploadOverride = () async {
        uploadCount++;
        return const Res(true);
      };

      final source = _source();
      source.data = {'token': 'first'};
      final firstSave = source.saveData();
      source.data = {'token': 'second'};
      final secondSave = source.saveData();
      source.data = {'token': 'third'};
      final thirdSave = source.saveData();

      await Future.wait([firstSave, secondSave, thirdSave]);
      await pumpEventQueue();

      final savedFile = File('${dataDir.path}/comic_source/test.data');
      final savedData = jsonDecode(savedFile.readAsStringSync());

      expect(savedData['token'], 'third');
      expect(uploadCount, 2);
    },
  );
}

ComicSource _source() {
  return ComicSource(
    'Test Source',
    'test',
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
