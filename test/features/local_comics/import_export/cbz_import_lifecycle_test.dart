import 'package:venera_next/foundation/persistence_failure.dart';
import 'dart:convert';
import 'dart:async';
import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager manager;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('cbz-lifecycle-');
    App.dataPath = root.path;
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  File book(String name, {int? chapterEnd, bool nested = false}) {
    final contents = archive.Archive();
    final prefix = nested ? 'wrapped/' : '';
    final entries = {
      '${prefix}1.jpg': name,
      '${prefix}metadata.json': jsonEncode({
        'title': name,
        'author': 'Author',
        'tags': ['tag'],
        if (chapterEnd != null)
          'chapters': [
            {'title': 'Chapter', 'start': 1, 'end': chapterEnd},
          ],
      }),
    };
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      contents.addFile(archive.ArchiveFile(entry.key, bytes.length, bytes));
    }
    return File('${root.path}/$name.cbz')
      ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
  }

  test(
    'WebDAV restore keeps the real archive importer guarded until registration',
    () async {
      final gate = Completer<void>();
      final registering = Completer<void>();
      final oldOps = ComicBackupManager.ops;
      final oldImporter = ComicBackupManager.importComic;
      final oldRegister = ComicBackupManager.registerImportedComic;
      final oldConfig = appdata.settings['backupWebdav'];
      final oldPath = appdata.settings['backupWebdavPath'];
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = '/backup';
      ComicBackupManager.ops = _ArchiveDownloadOps(book('Restored'));
      ComicBackupManager.importComic = null;
      ComicBackupManager.registerImportedComic = (comic) async {
        registering.complete();
        await gate.future;
        await manager.add(comic, comic.id);
      };
      final restoring = ComicBackupManager.restore([
        BackupFile(name: 'Restored.cbz', size: 1, modified: DateTime(2024)),
      ]);
      try {
        await registering.future;
        await expectLater(
          manager.runWithExclusiveStorage(() async {}),
          throwsA(isA<LocalComicStorageBusy>()),
        );
        gate.complete();
        final result = await restoring;
        expect(result.success, 1);
        expect(result.failed, 0);
        expect(manager.findByName('Restored'), isNotNull);
        expect(Directory(App.cachePath).listSync(), isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await restoring;
        ComicBackupManager.ops = oldOps;
        ComicBackupManager.importComic = oldImporter;
        ComicBackupManager.registerImportedComic = oldRegister;
        appdata.settings['backupWebdav'] = oldConfig;
        appdata.settings['backupWebdavPath'] = oldPath;
      }
    },
  );

  test(
    'storage protects archive extraction through awaited registration',
    () async {
      final migrationGate = Completer<void>();
      final registrationGate = Completer<void>();
      final registering = Completer<LocalComic>();
      final exclusive = manager.runWithExclusiveStorage(
        () => migrationGate.future,
      );
      final importing = CBZ.import(
        book('Guarded'),
        registerComic: (comic) async {
          registering.complete(comic);
          await registrationGate.future;
          await manager.add(comic, comic.id);
        },
      );
      addTearDown(() async {
        if (!migrationGate.isCompleted) migrationGate.complete();
        if (!registrationGate.isCompleted) registrationGate.complete();
        await exclusive;
        await importing;
      });
      await pumpEventQueue();
      expect(Directory(App.cachePath).listSync(), isEmpty);
      expect(registering.isCompleted, isFalse);
      migrationGate.complete();
      await exclusive;
      await registering.future;
      expect(manager.findByName('Guarded'), isNull);
      await expectLater(
        manager.runWithExclusiveStorage(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      registrationGate.complete();
      await importing;
      expect(manager.findByName('Guarded'), isNotNull);
      await manager.runWithExclusiveStorage(() async {});
    },
  );

  test(
    'backup restore reports a failed acknowledgement without deleting saved pages',
    () async {
      final oldOps = ComicBackupManager.ops;
      final oldImporter = ComicBackupManager.importComic;
      final oldRegister = ComicBackupManager.registerImportedComic;
      final oldConfig = appdata.settings['backupWebdav'];
      final oldPath = appdata.settings['backupWebdavPath'];
      final error = StateError('restore acknowledgement failed');
      appdata.settings['backupWebdav'] = ['https://example.com/dav', 'u', 'p'];
      appdata.settings['backupWebdavPath'] = '/backup';
      ComicBackupManager.ops = _ArchiveDownloadOps(book('Restored'));
      ComicBackupManager.importComic = null;
      ComicBackupManager.registerImportedComic = (comic) async {
        await manager.add(comic, comic.id);
        throw error;
      };
      try {
        final result = await ComicBackupManager.restore([
          BackupFile(name: 'Restored.cbz', size: 1, modified: DateTime(2024)),
        ]);
        expect(result.success, 0);
        expect(result.failed, 1);
        expect(
          result.failures.single.error,
          isA<PersistenceFailure>()
              .having(
                (failure) => failure.commitState,
                'state',
                PersistenceCommitState.unknown,
              )
              .having((failure) => failure.cause, 'cause', same(error)),
        );
        final saved = manager.findByName('Restored')!;
        expect(
          File(
            '${manager.path}/${saved.directory}/${saved.cover}',
          ).readAsStringSync(),
          'Restored',
        );
        expect(Directory(App.cachePath).listSync(), isEmpty);
      } finally {
        ComicBackupManager.ops = oldOps;
        ComicBackupManager.importComic = oldImporter;
        ComicBackupManager.registerImportedComic = oldRegister;
        appdata.settings['backupWebdav'] = oldConfig;
        appdata.settings['backupWebdavPath'] = oldPath;
      }
    },
  );

  test('registration error removes archive output and permits retry', () async {
    final error = PersistenceFailure(
      commitState: PersistenceCommitState.notCommitted,
      cause: StateError('registration rejected'),
      stackTrace: StackTrace.current,
    );
    await expectLater(
      CBZ.import(book('Register'), registerComic: (_) async => throw error),
      throwsA(same(error)),
    );
    expect(Directory('${manager.path}/Register').existsSync(), isFalse);
    expect(Directory(App.cachePath).listSync(), isEmpty);
    await manager.runWithExclusiveStorage(() async {});
    await CBZ.import(
      book('Register'),
      registerComic: (comic) => manager.add(comic, comic.id),
    );
    expect(manager.findByName('Register'), isNotNull);
  });

  test(
    'concurrent archives retain separate workspaces, pages and awaited covers',
    () async {
      final comics = await Future.wait([
        CBZ.import(book('First', nested: true)),
        CBZ.import(book('Second', chapterEnd: 1)),
      ]);
      for (final comic in comics) {
        final output = '${manager.path}/${comic.directory}';
        expect(File('$output/${comic.cover}').readAsStringSync(), comic.title);
        final page = comic.hasChapters ? '0/1.jpg' : '1.jpg';
        expect(File('$output/$page').readAsStringSync(), comic.title);
        expect(comic.subtitle, 'Author');
        expect(comic.tags, ['tag']);
      }
      expect(comics.last.chapters!.ids, ['0']);
      expect(Directory(App.cachePath).listSync(), isEmpty);
    },
  );

  test(
    'failure after cover copy cleans owned output and permits retry',
    () async {
      await expectLater(
        CBZ.import(book('Retry', chapterEnd: 2)),
        throwsRangeError,
      );
      expect(Directory('${manager.path}/Retry').existsSync(), isFalse);
      expect(Directory(App.cachePath).listSync(), isEmpty);
      final comic = await CBZ.import(book('Retry', chapterEnd: 1));
      expect(
        File(
          '${manager.path}/${comic.directory}/${comic.cover}',
        ).readAsStringSync(),
        'Retry',
      );
    },
  );

  test(
    'existing empty directory or file is never adopted or removed',
    () async {
      final directory = Directory('${manager.path}/Occupied')..createSync();
      await expectLater(
        CBZ.import(book('Occupied')),
        throwsA(isA<FileSystemException>()),
      );
      expect(directory.existsSync(), isTrue);
      expect(directory.listSync(), isEmpty);
      directory.deleteSync();
      final existing = File(directory.path)..writeAsStringSync('keep');
      await expectLater(
        CBZ.import(book('Occupied')),
        throwsA(isA<FileSystemException>()),
      );
      expect(existing.readAsStringSync(), 'keep');
      expect(Directory(App.cachePath).listSync(), isEmpty);
    },
  );
}

class _ArchiveDownloadOps implements ComicBackupWebDavOps {
  _ArchiveDownloadOps(this.archiveFile);
  final File archiveFile;

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) async {
    await archiveFile.copy(localPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
