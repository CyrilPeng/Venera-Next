import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  setUp(() {
    configureComicSourceDataSavedHandler(null);
  });

  tearDown(() {
    configureComicSourceDataSavedHandler(null);
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
      configureComicSourceDataSavedHandler(() async {
        uploadCount++;
      });

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

  test(
    'close drains coalesced writes and their change notifications',
    () async {
      final root = Directory.systemTemp.createTempSync('source-save-close-');
      addTearDown(() => root.deleteSync(recursive: true));
      App.dataPath = root.path;
      final notified = Completer<void>();
      final releaseNotification = Completer<void>();
      var notifications = 0;
      configureComicSourceDataSavedHandler(() async {
        notifications++;
        if (notifications == 1) {
          notified.complete();
          await releaseNotification.future;
        }
      });

      final source = _source();
      source.data = {'token': 'first'};
      final first = source.saveData();
      await notified.future;
      source.data = {'token': 'second'};
      final second = source.saveData();
      source.data = {'token': 'latest'};
      final third = source.saveData();
      expect(third, same(second));
      final closing = source.closeDataWrites();
      expect(source.closeDataWrites(), same(closing));
      var closed = false;
      final observed = closing.then((_) => closed = true);
      await expectLater(source.saveData(), throwsStateError);
      await pumpEventQueue();
      expect(closed, isFalse);

      releaseNotification.complete();
      await Future.wait([first, second, third, observed]);
      expect(notifications, 2);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'latest'},
      );
    },
  );

  test(
    'close retains an unobserved file failure after the save settles',
    () async {
      final root = Directory.systemTemp.createTempSync('source-save-failure-');
      addTearDown(() => root.deleteSync(recursive: true));
      App.dataPath = root.path;
      Directory(
        '${root.path}/comic_source/test.data',
      ).createSync(recursive: true);
      final source = _source();
      // The production JavaScript bridge intentionally cannot await saveData.
      source.saveData();
      await pumpEventQueue();
      await expectLater(
        source.closeDataWrites(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('a successful retry repairs the retained save failure', () async {
    final root = Directory.systemTemp.createTempSync('source-save-retry-');
    addTearDown(() => root.deleteSync(recursive: true));
    App.dataPath = root.path;
    final obstruction = Directory('${root.path}/comic_source/test.data')
      ..createSync(recursive: true);
    final source = _source();
    await expectLater(source.saveData(), throwsA(isA<FileSystemException>()));
    obstruction.deleteSync();
    source.data = {'token': 'recovered'};
    await source.saveData();
    await source.closeDataWrites();
    expect(
      jsonDecode(
        File('${root.path}/comic_source/test.data').readAsStringSync(),
      ),
      {'token': 'recovered'},
    );
  });

  test(
    'closed source observes ignored saves and still rejects awaiters',
    () async {
      final source = _source();
      await source.closeDataWrites();
      // JavaScript save_data returns void, including during shutdown.
      source.saveData();
      await pumpEventQueue();
      await expectLater(source.saveData(), throwsStateError);
    },
  );

  test('comic type resolves source data through comic source bridge', () {
    const key = 'comic_type_bridge_test_source';
    final manager = ComicSourceManager();
    manager.remove(key);
    final source = _source(key: key);
    manager.add(source);
    addTearDown(() => manager.remove(key));

    final type = ComicType.fromKey(key);

    expect(type.sourceKey, key);
    expect(type.comicSource, same(source));
  });

  test('check source updates skips when source list url is empty', () async {
    const key = 'comic_source_update_without_repo';
    final manager = ComicSourceManager();
    manager.remove(key);
    final source = _source(key: key);
    manager.add(source);
    final previousListUrl = appdata.settings['comicSourceListUrl'];
    appdata.settings['comicSourceListUrl'] = '';
    addTearDown(() {
      appdata.settings['comicSourceListUrl'] = previousListUrl;
      manager.remove(key);
    });

    final count = await SourceUpdateService.instance.checkUpdates();

    expect(count, 0);
    expect(ComicSourceManager().availableUpdates, isEmpty);
  });
}

ComicSource _source({String key = 'test'}) {
  return ComicSource(
    'Test Source',
    key,
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
    '$key.js',
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
