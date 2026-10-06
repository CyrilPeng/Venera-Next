import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/comic_source/source.dart';
import 'package:venera_next/features/comic_source/source_data_journal.dart';
import 'package:venera_next/features/comic_source/source_data_storage.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

import '../../support/comic_source_fixture.dart';
import '../../support/source_data_files.dart';

void main() {
  late Directory root;
  late ControlledSourceDataFiles files;
  late SourceDataStorage storage;
  late ComicSource source;
  setUp(() {
    root = Directory.systemTemp.createTempSync('source-runtime-cleanup-');
    App.dataPath = root.path;
    files = ControlledSourceDataFiles();
    storage = SourceDataStorage(files: files);
    source = ComicSourceFixture(dataStorage: storage);
    configureComicSourceDataSavedHandler(null);
  });
  tearDown(() async {
    files.beforeRemoveDirectory = null;
    configureComicSourceDataSavedHandler(null);
    try {
      await source.closeDataWrites();
    } on SourceMutationFailure {
      // Tests retain failed saves/conflicts and assert their original results.
    }
    await root.delete(recursive: true);
  });

  Future<SourceDataWriteFailure> failSave({bool applied = true}) async {
    files.beforeRemoveDirectory = (_) =>
        throw const FileSystemException('cleanup denied');
    if (!applied) {
      files.beforeReplace = (_, _) =>
          throw const FileSystemException('replace denied');
    }
    try {
      await source.editData((draft) => draft['token'] = 'new');
      throw StateError('Expected failed cleanup');
    } on SourceDataWriteFailure catch (failure) {
      expect(
        failure.state,
        applied
            ? SourceMutationState.applied
            : SourceMutationState.recoveryRequired,
      );
      return failure;
    } finally {
      files.beforeRemoveDirectory = null;
      files.beforeReplace = null;
    }
  }

  File live() => File('${root.path}/comic_source/fixture.data');
  File journal() => File('${root.path}/.source-data-recovery/ownership.sqlite');

  test(
    'cleanup retry preserves later data without writing or notifying',
    () async {
      var notifications = 0;
      configureComicSourceDataSavedHandler(() async => notifications++);
      final failure = await failSave();
      await live().writeAsString('{"token":"later"}');
      files.beforeWrite = (_, _) => throw StateError('must not save again');
      await source.retryDataCleanup();
      await source.retryDataCleanup();
      await source.closeDataWrites();
      expect(Directory(failure.recoveryPath!).existsSync(), isFalse);
      expect(await live().readAsString(), '{"token":"later"}');
      expect(notifications, 1);
    },
  );

  test('cleanup success does not acknowledge an uncommitted save', () async {
    await source.editData((draft) => draft['token'] = 'old');
    final failure = await failSave(applied: false);
    await source.retryDataCleanup();
    expect(Directory(failure.recoveryPath!).existsSync(), isFalse);
    expect(await live().readAsString(), '{"token":"old"}');
    await expectLater(source.closeDataWrites(), throwsA(same(failure)));
  });

  test(
    'external conflict preserves original and retry errors until repaired',
    () async {
      final failure = await failSave();
      final conflict = File('${failure.recoveryPath}/contents')
        ..writeAsStringSync('external data');
      await expectLater(
        source.retryDataCleanup(),
        throwsA(
          isA<SourceMutationFailure>()
              .having(
                (e) => e.failures.map((f) => f.error),
                'original failure',
                contains(same(failure)),
              )
              .having((e) => e.failures.length, 'retry diagnosis', 2),
        ),
      );
      expect(conflict.readAsStringSync(), 'external data');
      await conflict.delete();
      await source.retryDataCleanup();
      await source.closeDataWrites();
    },
  );

  test(
    'later successful save keeps unresolved cleanup visible at close',
    () async {
      final failure = await failSave();
      final conflict = File('${failure.recoveryPath}/contents')
        ..writeAsStringSync('external data');
      await source.editData((draft) => draft['token'] = 'later');
      expect(await live().readAsString(), '{"token":"later"}');
      await expectLater(
        source.closeDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.failures.map((f) => f.error),
            'old cleanup',
            contains(same(failure)),
          ),
        ),
      );
      expect(conflict.readAsStringSync(), 'external data');
    },
  );

  test('retry does not reclaim a later live write with the same key', () async {
    final failure = await failSave();
    final entered = Completer<void>();
    final release = Completer<void>();
    File? active;
    final otherFiles = ControlledSourceDataFiles()
      ..beforeReplace = (temporary, _) async {
        active = temporary;
        entered.complete();
        await release.future;
      };
    final writing = SourceDataStorage(
      files: otherFiles,
    ).write(root.path, 'fixture', '{"token":"concurrent"}');
    try {
      await entered.future;
      await source.retryDataCleanup();
      expect(Directory(failure.recoveryPath!).existsSync(), isFalse);
      expect(active!.existsSync(), isTrue);
    } finally {
      release.complete();
      await writing;
    }
    await source.closeDataWrites();
    expect(await live().readAsString(), '{"token":"concurrent"}');
  });

  test(
    'disk recovery can complete before the runtime acknowledges cleanup',
    () async {
      await failSave();
      await const SourceDataStorage().recover(root.path);
      await source.retryDataCleanup();
      await source.closeDataWrites();
    },
  );

  test('missing journal record cannot hide a retained directory', () async {
    final failure = await failSave();
    final db = sqlite3.open(journal().path);
    db.execute('DELETE FROM writes');
    db.dispose();
    await expectLater(
      source.retryDataCleanup(),
      throwsA(isA<SourceMutationFailure>()),
    );
    expect(Directory(failure.recoveryPath!).existsSync(), isTrue);
    // A separately confirmed removal can be acknowledged, but never inferred.
    await Directory(failure.recoveryPath!).delete();
    await source.retryDataCleanup();
    await source.closeDataWrites();
  });

  test(
    'a changed but internally valid record is not the runtime receipt',
    () async {
      final failure = await failSave();
      final db = sqlite3.open(journal().path);
      db.execute("UPDATE writes SET source_key = 'another'");
      db.dispose();
      await expectLater(
        source.retryDataCleanup(),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(Directory(failure.recoveryPath!).existsSync(), isTrue);
      final repaired = sqlite3.open(journal().path);
      repaired.execute("UPDATE writes SET source_key = 'fixture'");
      repaired.dispose();
      await source.retryDataCleanup();
    },
  );

  test(
    'queued retry is invalidated by a source freeze before admission',
    () async {
      final failure = await failSave();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() async {
        await release.future;
        final freeze = source.freezeDataWrites();
        await freeze.waitForWrites();
        freeze.resume();
      });
      final rejected = expectLater(source.retryDataCleanup(), throwsStateError);
      release.complete();
      await Future.wait([exclusive, rejected]);
      expect(Directory(failure.recoveryPath!).existsSync(), isTrue);
      await source.retryDataCleanup();
    },
  );

  test(
    'close drains accepted retry and cleans its original directory',
    () async {
      final failure = await failSave();
      final entered = Completer<void>();
      final release = Completer<void>();
      files.beforeRemoveDirectory = (_) async {
        entered.complete();
        await release.future;
      };
      final retry = source.retryDataCleanup();
      await entered.future;
      final next = Directory('${root.path}/next')..createSync();
      App.dataPath = next.path;
      var closed = false;
      final closing = source.closeDataWrites().then((_) => closed = true);
      try {
        await pumpEventQueue();
        expect(closed, isFalse);
        await expectLater(source.retryDataCleanup(), throwsStateError);
      } finally {
        release.complete();
        await Future.wait([retry, closing]);
      }
      expect(Directory(failure.recoveryPath!).existsSync(), isFalse);
      expect(next.listSync(), isEmpty);
    },
  );

  test(
    'missing journal directory still requires proof that residue is gone',
    () async {
      final failure = await failSave();
      await journal().parent.delete(recursive: true);
      await expectLater(
        source.retryDataCleanup(),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(Directory(failure.recoveryPath!).existsSync(), isTrue);
      await Directory(failure.recoveryPath!).delete();
      await source.retryDataCleanup();
      await source.closeDataWrites();
    },
  );

  test(
    'an adapter without a cleanup receipt cannot erase its failure',
    () async {
      final retained = Directory('${root.path}/unowned')..createSync();
      final keep = File('${retained.path}/contents')..writeAsStringSync('keep');
      final failure = SourceMutationFailure(
        state: SourceMutationState.applied,
        recoveryPath: retained.path,
        failures: [
          (
            stage: 'adapter cleanup',
            error: StateError('failed'),
            stack: StackTrace.current,
          ),
        ],
      );
      source = ComicSourceFixture(dataStorage: _UnownedFailureStorage(failure));
      await expectLater(source.saveData(), throwsA(same(failure)));
      await expectLater(
        source.retryDataCleanup(),
        throwsA(isA<SourceMutationFailure>()),
      );
      await expectLater(
        source.closeDataWrites(),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(keep.readAsStringSync(), 'keep');
    },
  );

  test('cleanup works inside preparation and exclusive admission', () async {
    await failSave();
    await AppDataOperations.instance.prepare(source.retryDataCleanup);
    await failSave();
    await AppDataOperations.instance.run(source.retryDataCleanup);
    await source.closeDataWrites();
  });

  test(
    'successful disk cleanup cannot acknowledge failed native release',
    () async {
      final nativeFailure = SourceDataResourceReleaseFailure(
        const FileSystemException('native close incomplete'),
        StackTrace.current,
        '${root.path}/ownership.lock',
      );
      files.beforeRemoveDirectory = (_) => throw nativeFailure;
      SourceDataWriteFailure? failure;
      try {
        await source.saveData();
        fail('Expected resource release failure');
      } on SourceDataWriteFailure catch (error) {
        failure = error;
      }
      expect(failure.cleanupResolvesFailure, isFalse);
      files.beforeRemoveDirectory = null;
      await expectLater(
        source.retryDataCleanup(),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(Directory(failure.recoveryPath!).existsSync(), isFalse);
      await expectLater(
        source.closeDataWrites(),
        throwsA(isA<SourceMutationFailure>()),
      );
      expect(failure.failures.single.error, same(nativeFailure));
    },
  );

  test(
    'cleanup success leaves failed publication for close to retry',
    () async {
      final notificationFailure = StateError('notification failed');
      files.beforeRemoveDirectory = (_) =>
          throw const FileSystemException('cleanup denied');
      configureComicSourceDataSavedHandler(
        () async => throw notificationFailure,
      );
      await expectLater(
        source.saveData(),
        throwsA(isA<SourceMutationFailure>()),
      );
      files.beforeRemoveDirectory = null;
      await source.retryDataCleanup();
      await expectLater(
        source.closeDataWrites(),
        throwsA(
          isA<SourceMutationFailure>().having(
            (e) => e.cause,
            'publication',
            same(notificationFailure),
          ),
        ),
      );
    },
  );
}

class _UnownedFailureStorage extends SourceDataStorage {
  _UnownedFailureStorage(this.failure);
  final SourceMutationFailure failure;
  @override
  Future<void> write(String path, String key, String contents) async =>
      throw failure;
}
