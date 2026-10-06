import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import '../../support/comic_source_fixture.dart';
import '../../support/source_data_files.dart';

void main() {
  late Directory root;
  late ControlledSourceDataFiles files;
  late ComicSource source;
  setUp(() {
    root = Directory.systemTemp.createTempSync('source-edit-');
    App.dataPath = root.path;
    files = ControlledSourceDataFiles();
    source = ComicSourceFixture(dataStorage: SourceDataStorage(files: files));
    configureComicSourceDataSavedHandler(null);
  });
  tearDown(() async {
    configureComicSourceDataSavedHandler(null);
    await source.closeDataWrites();
    await root.delete(recursive: true);
  });
  Map saved() =>
      jsonDecode(
            File('${root.path}/comic_source/fixture.data').readAsStringSync(),
          )
          as Map;

  test(
    'published nested data and retained drafts cannot mutate the source',
    () async {
      Map<String, dynamic>? retained;
      final input = <dynamic>[
        <String, dynamic>{'value': 1},
      ];
      await source.editData((draft) {
        retained = draft;
        draft['nested'] = input;
      });
      final before = source.data;
      expect(() => before['new'] = true, throwsUnsupportedError);
      expect(() => (before['nested'] as List).add(2), throwsUnsupportedError);
      expect(() => before['nested'][0]['value'] = 2, throwsUnsupportedError);
      retained!['nested'][0]['value'] = 3;
      input.add(4);
      await source.editData((draft) => draft['other'] = true);
      expect(before, {
        'nested': [
          {'value': 1},
        ],
      });
      expect(source.data, {
        'nested': [
          {'value': 1},
        ],
        'other': true,
      });
      expect(saved(), source.data);
    },
  );

  test(
    'constructor and staged snapshots detach all caller containers',
    () async {
      final input = <String, dynamic>{
        'nested': [1],
      };
      final initialized = ComicSourceFixture(initialData: input);
      input['nested'].add(2);
      expect(initialized.data['nested'], [1]);
      source.stageDataWrites(initialData: input);
      input['nested'].add(3);
      expect(source.data['nested'], [1, 2]);
      await source.saveData();
      await source.commitDataWrites();
      expect(saved()['nested'], [1, 2]);
      await initialized.closeDataWrites();
    },
  );

  test(
    'queued edits merge at admission and close drains accepted work',
    () async {
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final first = source.editData((draft) => draft['one'] = 1);
      final second = source.editData((draft) => draft['two'] = 2);
      expect(source.data, isEmpty);
      var closed = false;
      final closing = source.closeDataWrites().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      release.complete();
      await Future.wait([exclusive, first, second, closing]);
      expect(saved(), {'one': 1, 'two': 2});
    },
  );

  test('invalidated queued edit never runs its draft callback', () async {
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() async {
      await release.future;
      final freeze = source.freezeDataWrites();
      await freeze.waitForWrites();
      freeze.resume();
    });
    var calls = 0;
    final rejected = expectLater(
      source.editData((draft) {
        calls++;
        draft['old'] = true;
      }),
      throwsStateError,
    );
    release.complete();
    await Future.wait([exclusive, rejected]);
    expect(calls, 0);
    expect(source.data, isEmpty);
  });

  test(
    'retry only saves current contents and never reapplies an older edit',
    () async {
      var edits = 0;
      final request = source.prepareDataEdit((draft) {
        edits++;
        draft['value'] = 'first';
      });
      files.beforeWrite = (_, _) =>
          throw const FileSystemException('disk full');
      await expectLater(request.save(), throwsA(isA<FileSystemException>()));
      expect(source.data['value'], 'first');
      files.beforeWrite = null;
      await source.editData((draft) {
        draft['value'] = 'new';
        draft['other'] = true;
      });
      await request.save();
      expect(edits, 1);
      expect(saved(), {'value': 'new', 'other': true});
    },
  );

  test(
    'directory changes reject unadmitted edits before memory publication',
    () async {
      final request = source.prepareDataEdit((draft) => draft['wrong'] = true);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final rejected = expectLater(request.save(), throwsStateError);
      App.dataPath = '${root.path}/other';
      release.complete();
      await Future.wait([exclusive, rejected]);
      expect(source.data, isEmpty);
      expect(
        File('${root.path}/comic_source/fixture.data').existsSync(),
        isFalse,
      );
      App.dataPath = root.path;
    },
  );

  test(
    'throwing or unserializable drafts leave the prior snapshot intact',
    () async {
      await source.editData((draft) => draft['value'] = 1);
      final snapshot = source.data;
      await expectLater(
        source.editData((draft) {
          draft['value'] = 2;
          throw StateError('invalid');
        }),
        throwsStateError,
      );
      await expectLater(
        source.editData((draft) => draft['bad'] = Object()),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(source.data, same(snapshot));
      expect(saved(), snapshot);
    },
  );

  test(
    'cookie authentication is not repeated after a failed credential save',
    () async {
      var validations = 0;
      final loginSource = ComicSourceFixture(
        key: 'login',
        dataStorage: SourceDataStorage(files: files),
        account: AccountConfig(
          null,
          null,
          null,
          () {},
          null,
          null,
          ['session'],
          (values) async {
            validations++;
            expect(values, ['secret']);
            return true;
          },
        ),
      );
      final request = SourceLoginAttempt.cookies(loginSource, ['secret']);
      files.beforeWrite = (_, _) =>
          throw const FileSystemException('disk full');
      await expectLater(request.save(), throwsA(isA<FileSystemException>()));
      files.beforeWrite = null;
      await loginSource.editData((draft) => draft['later'] = true);
      expect((await request.save()).data, isTrue);
      expect(validations, 1);
      expect(loginSource.data, {'account': 'ok', 'later': true});
      await loginSource.closeDataWrites();
    },
  );
}
