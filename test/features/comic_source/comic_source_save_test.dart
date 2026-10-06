import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import '../../support/source_data_files.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
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
    'saveData owns each accepted snapshot and excludes later unsaved edits',
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
      final firstSave = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      final secondSave = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'second'});
      });
      final thirdSave = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'third'});
      });
      expect(() => source.data['token'] = 'unsaved', throwsUnsupportedError);

      await Future.wait([firstSave, secondSave, thirdSave]);
      await pumpEventQueue();

      final savedFile = File('${dataDir.path}/comic_source/test.data');
      final savedData = jsonDecode(savedFile.readAsStringSync());

      expect(savedData['token'], 'third');
      expect(uploadCount, 3);
    },
  );

  test(
    'close drains independently admitted writes and their change notifications',
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
      final first = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      await notified.future;
      final second = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'second'});
      });
      final third = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'latest'});
      });
      expect(third, isNot(same(second)));
      final closing = source.closeDataWrites();
      expect(source.closeDataWrites(), same(closing));
      var closed = false;
      final observed = closing.then((_) => closed = true);
      await expectLater(source.saveData(), throwsStateError);
      await pumpEventQueue();
      expect(closed, isFalse);

      releaseNotification.complete();
      await Future.wait([first, second, third, observed]);
      expect(notifications, 3);
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
    await source.editData((draft) {
      draft
        ..clear()
        ..addAll({'token': 'recovered'});
    });
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

  test(
    'queued save retains its original path and deeply captured contents',
    () async {
      final root = Directory.systemTemp.createTempSync('source-save-snapshot-');
      final source = _source(
        initialData: {
          'nested': [1],
        },
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await exclusive;
        await source.closeDataWrites();
        await root.delete(recursive: true);
      });
      final original = Directory('${root.path}/original')..createSync();
      final other = Directory('${root.path}/other')..createSync();
      App.dataPath = original.path;
      final save = source.saveData();
      expect(
        () => (source.data['nested'] as List).add(2),
        throwsUnsupportedError,
      );
      App.dataPath = other.path;
      release.complete();
      await save;
      expect(
        jsonDecode(
          File('${original.path}/comic_source/test.data').readAsStringSync(),
        ),
        {
          'nested': [1],
        },
      );
      expect(
        File('${other.path}/comic_source/test.data').existsSync(),
        isFalse,
      );
      await expectLater(source.saveData(), throwsStateError);
    },
  );

  test(
    'notification can await exclusive work after file admission releases',
    () async {
      final root = Directory.systemTemp.createTempSync('source-save-notify-');
      final source = _source();
      App.dataPath = root.path;
      addTearDown(() async {
        await source.closeDataWrites();
        await root.delete(recursive: true);
      });
      configureComicSourceDataSavedHandler(
        () => AppDataOperations.instance.run(() {
          expect(
            jsonDecode(
              File('${root.path}/comic_source/test.data').readAsStringSync(),
            ),
            {'token': 'saved'},
          );
        }),
      );
      await source
          .editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'saved'});
          })
          .timeout(const Duration(seconds: 5));
    },
  );

  test(
    'exclusive save never joins an outside request queued behind itself',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-save-admission-',
      );
      final source = _source();
      App.dataPath = root.path;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() async {
        await release.future;
        await source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'inside'});
        });
        expect(
          jsonDecode(
            File('${root.path}/comic_source/test.data').readAsStringSync(),
          ),
          {'token': 'inside'},
        );
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await exclusive;
        await source.closeDataWrites();
        await root.delete(recursive: true);
      });
      final outside = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'outside'});
      });
      release.complete();
      await Future.wait([
        exclusive,
        outside,
      ]).timeout(const Duration(seconds: 5));
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'outside'},
      );
    },
  );

  test(
    'close waits for accepted saves that have not acquired admission',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-save-queued-close-',
      );
      final source = _source();
      App.dataPath = root.path;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await exclusive;
        await source.closeDataWrites();
        await root.delete(recursive: true);
      });
      final saving = source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'accepted'});
      });
      var closed = false;
      final closing = source.closeDataWrites().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      await Future.wait([saving, closing]);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'accepted'},
      );
    },
  );

  test(
    'freeze invalidates pending admission and resumed edits persist independently',
    () async {
      final root = Directory.systemTemp.createTempSync('source-save-freeze-');
      final source = _source(initialData: {'token': 'old'});
      App.dataPath = root.path;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() async {
        await release.future;
        final freeze = source.freezeDataWrites();
        await freeze.waitForWrites();
        expect(
          () => source.editDataSync((draft) => draft['token'] = 'rejected'),
          throwsStateError,
        );
        expect(source.data, {'token': 'old'});
        freeze.resume();
        source.editDataSync((draft) => draft['token'] = 'resumed');
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await exclusive;
        await source.closeDataWrites();
        await root.delete(recursive: true);
      });
      final rejected = expectLater(
        source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'old'});
        }),
        throwsStateError,
      );
      release.complete();
      await Future.wait([
        exclusive,
        rejected,
      ]).timeout(const Duration(seconds: 5));
      await source.closeDataWrites();
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'resumed'},
      );
    },
  );

  test(
    'synchronous edits reject replacement and invalid JSON before changing memory',
    () async {
      final root = Directory.systemTemp.createTempSync('source-edit-reject-');
      final source = _source();
      App.dataPath = root.path;
      await source.editData((draft) => draft['token'] = 'original');
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      expect(
        () => source.editDataSync((draft) => draft['token'] = 'blocked'),
        throwsA(isA<AppDataBusyException>()),
      );
      release.complete();
      await exclusive;
      expect(
        () => source.editDataSync((draft) => draft['bad'] = Object()),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(source.data, {'token': 'original'});
      await source.closeDataWrites();
      await root.delete(recursive: true);
    },
  );

  test(
    'staged commit uses the last accepted snapshot, excluding unsaved edits',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-staged-snapshot-',
      );
      Directory('${root.path}/comic_source').createSync();
      App.dataPath = root.path;
      final source = _source();
      source.stageDataWrites();
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'accepted'});
      });
      expect(() => source.data['token'] = 'unsaved', throwsUnsupportedError);
      await source.commitDataWrites();
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'accepted'},
      );
      await source.closeDataWrites();
      await root.delete(recursive: true);
    },
  );

  test(
    'a queued read cannot overwrite memory after its source was frozen',
    () async {
      final root = Directory.systemTemp.createTempSync('source-read-freeze-');
      Directory('${root.path}/comic_source').createSync();
      File(
        '${root.path}/comic_source/test.data',
      ).writeAsStringSync('{"token":"disk"}');
      App.dataPath = root.path;
      final source = _source(initialData: {'token': 'memory'});
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() async {
        await release.future;
        final freeze = source.freezeDataWrites();
        await freeze.waitForWrites();
        freeze.resume();
      });
      final rejected = expectLater(source.loadData(), throwsStateError);
      release.complete();
      await Future.wait([exclusive, rejected]);
      expect(source.data, {'token': 'memory'});
      await source.loadData();
      expect(source.data, {'token': 'disk'});
      await source.closeDataWrites();
      await expectLater(source.loadData(), throwsStateError);
      await root.delete(recursive: true);
    },
  );

  test(
    'ordinary partial write leaves previous credentials intact and removes staging',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-atomic-failure-',
      );
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      addTearDown(() => root.delete(recursive: true));
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'old'});
      });
      final failure = FileSystemException('disk full');
      files.beforeWrite = (temporary, _) async {
        await temporary.writeAsString('{"token":');
        throw failure;
      };
      await expectLater(
        source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'new'});
        }),
        throwsA(same(failure)),
      );
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'old'},
      );
      expect(
        Directory(
          '${root.path}/comic_source',
        ).listSync().whereType<Directory>(),
        isEmpty,
      );
      files.beforeWrite = null;
      await source.saveData();
      await source.closeDataWrites();
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'new'},
      );
    },
  );

  test(
    'staged commit drains snapshots accepted during replacement and close waits',
    () async {
      final root = Directory.systemTemp.createTempSync('source-commit-drain-');
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      final entered = Completer<void>();
      final release = Completer<void>();
      final written = <Object?>[];
      files.beforeReplace = (temporary, target) async {
        written.add(jsonDecode(await temporary.readAsString()));
        if (written.length == 1) {
          expect(await target.exists(), isFalse);
          entered.complete();
          await release.future;
        }
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      source.stageDataWrites();
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      final committing = source.commitDataWrites();
      await entered.future;
      await expectLater(source.commitDataWrites(), throwsStateError);
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'second'});
      });
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'third'});
      });
      expect(() => source.data['token'] = 'unsaved', throwsUnsupportedError);
      var closed = false;
      final closing = source.closeDataWrites().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      await Future.wait([committing, closing]);
      expect(written, [
        {'token': 'first'},
        {'token': 'third'},
      ]);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'third'},
      );
      await root.delete(recursive: true);
    },
  );

  test(
    'later staged failure stays applied and retries the accepted snapshot',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-commit-partial-',
      );
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      final entered = Completer<void>();
      final release = Completer<void>();
      var attempts = 0;
      files.beforeReplace = (_, _) async {
        if (++attempts == 1) {
          entered.complete();
          await release.future;
        } else {
          throw const FileSystemException('second write failed');
        }
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      source.stageDataWrites();
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      final failed = expectLater(
        source.commitDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.state,
            'state',
            SourceMutationState.applied,
          ),
        ),
      );
      await entered.future;
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'second'});
      });
      expect(() => source.data['token'] = 'not saved', throwsUnsupportedError);
      release.complete();
      await failed;
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'first'},
      );
      await expectLater(
        source.commitDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.state,
            'retry state',
            SourceMutationState.applied,
          ),
        ),
      );
      files.beforeReplace = null;
      await source.commitDataWrites();
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'second'},
      );
      await source.closeDataWrites();
      await root.delete(recursive: true);
    },
  );

  test(
    'staging closes after a partial commit so later ordinary saves persist',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-commit-handoff-',
      );
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      var attempts = 0;
      files.beforeReplace = (_, _) async {
        if (++attempts == 1) {
          await source.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'second'});
          });
        } else {
          throw const FileSystemException('second write failed');
        }
      };
      source.stageDataWrites();
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      await expectLater(
        source.commitDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.state,
            'state',
            SourceMutationState.applied,
          ),
        ),
      );
      files.beforeReplace = null;
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'ordinary'});
      });
      // A retry must not resurrect the failed, older staged snapshot.
      await source.commitDataWrites();
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'ordinary'},
      );
      await source.closeDataWrites();
      await root.delete(recursive: true);
    },
  );

  test(
    'cleanup failure retains applied state, notification and owned recovery path',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-cleanup-failure-',
      );
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      final failure = FileSystemException('directory cleanup denied');
      Directory? residue;
      files.beforeRemoveDirectory = (directory) {
        residue = directory;
        throw failure;
      };
      var notified = 0;
      configureComicSourceDataSavedHandler(() async {
        notified++;
      });
      await expectLater(
        source.editData((draft) {
          draft
            ..clear()
            ..addAll({'token': 'committed'});
        }),
        throwsA(
          isA<SourceMutationFailure>()
              .having((e) => e.state, 'state', SourceMutationState.applied)
              .having((e) => e.recoveryPath, 'owned path', isNotNull),
        ),
      );
      expect(notified, 1);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'committed'},
      );
      expect(residue!.existsSync(), isTrue);
      files.beforeRemoveDirectory = null;
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'later'});
      });
      // A later save retries the precise older residue before clearing it.
      expect(residue!.existsSync(), isFalse);
      await source.closeDataWrites();
      await root.delete(recursive: true);
    },
  );

  test(
    'callbacks during staged cleanup are committed before returning applied failure',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'source-staged-cleanup-',
      );
      App.dataPath = root.path;
      final files = ControlledSourceDataFiles();
      final source = _source(dataStorage: SourceDataStorage(files: files));
      var cleanups = 0;
      files.beforeRemoveDirectory = (_) async {
        if (++cleanups == 1) {
          await source.editData((draft) {
            draft
              ..clear()
              ..addAll({'token': 'late'});
          });
          throw const FileSystemException('cleanup denied');
        }
      };
      source.stageDataWrites();
      await source.editData((draft) {
        draft
          ..clear()
          ..addAll({'token': 'first'});
      });
      await expectLater(
        source.commitDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.state,
            'state',
            SourceMutationState.applied,
          ),
        ),
      );
      expect(cleanups, 2);
      expect(
        jsonDecode(
          File('${root.path}/comic_source/test.data').readAsStringSync(),
        ),
        {'token': 'late'},
      );
      await source.closeDataWrites();
      expect(cleanups, 3);
      await root.delete(recursive: true);
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

ComicSource _source({
  String key = 'test',
  SourceDataStorage dataStorage = const SourceDataStorage(),
  Map<String, dynamic> initialData = const {},
}) {
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
    dataStorage: dataStorage,
    initialData: initialData,
  );
}
