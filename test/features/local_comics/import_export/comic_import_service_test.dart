import 'package:venera_next/foundation/persistence_failure.dart';
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive_io.dart' as archive;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_metadata.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';

void main() {
  const service = ComicImportService(
    localManager: LocalManager.new,
    favoritesManager: LocalFavoritesManager.new,
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('comic-import-service-');
    App.dataPath = root.path;
    App.cachePath = root.path;
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

  LocalComic comicIn(String directory, String title) {
    Directory(directory).createSync(recursive: true);
    File(path.join(directory, '1.jpg')).writeAsStringSync('page');
    return LocalComic(
      id: '0',
      title: title,
      subtitle: 'Author',
      tags: ['tag'],
      directory: directory,
      chapters: null,
      cover: '1.jpg',
      comicType: ComicType.local,
      downloadedChapters: [],
      createdAt: DateTime(2024),
    );
  }

  Future<void> withFavorites(
    Future<void> Function(LocalFavoritesManager) action,
  ) async {
    final oldFollow = appdata.settings['followUpdatesFolder'];
    final oldQuick = appdata.settings['quickFavorite'];
    LocalFavoritesManager.cache = null;
    final favorites = LocalFavoritesManager();
    try {
      await favorites.init();
      await action(favorites);
    } finally {
      await favorites.debugWaitForHashedIdsRefresh();
      await appdata.saveData(false);
      favorites.close();
      LocalFavoritesManager.cache = null;
      appdata.settings['followUpdatesFolder'] = oldFollow;
      appdata.settings['quickFavorite'] = oldQuick;
    }
  }

  Future<ComicCopyRecord> pendingCopy({String? folder}) async {
    final source = comicIn('${root.path}/input/storage-name', 'Original title');
    final result = await copyComicDirectories(
      ComicDirectoryCopyRequest(
        directories: [source.directory],
        destination: manager.path,
        metadata: {source.directory: encodeComicCopyMetadata(source, folder)},
      ),
    );
    expect(result.failures, isEmpty);
    return ComicCopyRecord.read(Directory(result.copies[source.directory]!));
  }

  test(
    'recovery restores completed copy metadata and retires its markers',
    () async {
      final record = await pendingCopy();
      final result = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(result.importedCount, 1);
      expect(result.issues, isEmpty);
      final saved = manager.findByName('Original title')!;
      expect(saved.directory, record.directory.path);
      expect(saved.subtitle, 'Author');
      expect(saved.tags, ['tag']);
      expect(saved.createdAt, DateTime(2024));
      expect(ComicCopyRecord.exists(record.directory), isFalse);
      expect(File('${saved.directory}/1.jpg').readAsStringSync(), 'page');
      expect(
        (await service.runRecovery(
          (operation) => operation.localDownloads(isCancelled: () => false),
        )).importedCount,
        0,
      );
    },
  );

  test(
    'incomplete copy is preserved while unrelated legacy comics recover',
    () async {
      final source = comicIn('${root.path}/source', 'Unfinished');
      final partial = Directory('${manager.path}/partial')..createSync();
      ComicCopyRecord.prepare(
        partial,
        source: source.directory,
        metadata: encodeComicCopyMetadata(source, null),
      );
      File('${partial.path}/1.jpg').writeAsStringSync('first of three pages');
      comicIn('${manager.path}/Legacy', 'unused');
      final result = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(result.importedCount, 1);
      expect(
        result.issues.single.kind,
        ComicImportIssueKind.copyRecoveryRequired,
      );
      expect(manager.findByName('Unfinished'), isNull);
      expect(manager.findByName('Legacy'), isNotNull);
      expect(
        File('${partial.path}/1.jpg').readAsStringSync(),
        'first of three pages',
      );
      expect(ComicCopyRecord.exists(partial), isTrue);
    },
  );

  test(
    'changed completed payload does not register or discard evidence',
    () async {
      final record = await pendingCopy();
      File('${record.directory.path}/1.jpg').writeAsStringSync('edit');
      final result = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(result.importedCount, 0);
      expect(
        result.issues.any(
          (issue) => issue.kind == ComicImportIssueKind.copyRecoveryRequired,
        ),
        isTrue,
      );
      expect(manager.count, 0);
      expect(ComicCopyRecord.exists(record.directory), isTrue);
    },
  );

  for (final localOnly in [false, true]) {
    test(
      'favorite intent awaits an explicit current decision; localOnly=$localOnly',
      () async {
        await withFavorites((favorites) async {
          await favorites.createFolder('Original collection');
          await favorites.createFolder('Current choice');
          final record = await pendingCopy(folder: 'Original collection');
          final scanned = await service.runRecovery(
            (operation) => operation.localDownloads(isCancelled: () => false),
          );
          expect(scanned.importedCount, 0);
          expect(scanned.issues, isEmpty);
          expect(scanned.pendingCopies.single.title, 'Original title');
          expect(manager.count, 0);
          expect(favorites.getFolderComics('Original collection'), isEmpty);
          final choices = await service.runRecovery(
            (operation) async => operation.copyRecoveryFolders(),
          );
          final result = await service.runRecovery(
            (operation) => operation.recoverCopy(
              record.directory.path,
              folder: localOnly ? null : 'Current choice',
              intentDigest: scanned.pendingCopies.single.intentDigest,
              favorites: choices,
            ),
          );
          expect(result.importedCount, 1);
          expect(favorites.getFolderComics('Original collection'), isEmpty);
          expect(
            favorites.getFolderComics('Current choice'),
            hasLength(localOnly ? 0 : 1),
          );
          expect(ComicCopyRecord.exists(record.directory), isFalse);
        });
      },
    );
  }

  test(
    'same-path favorite replacement invalidates the displayed selection',
    () async {
      await withFavorites((favorites) async {
        await favorites.createFolder('Same name');
        final record = await pendingCopy(folder: 'Same name');
        final choices = await service.runRecovery(
          (operation) async => operation.copyRecoveryFolders(),
        );
        final databasePath = favorites.databasePath;
        await favorites.closeAndWait();
        File(databasePath).deleteSync();
        await favorites.init();
        await favorites.createFolder('Same name');
        final result = await service.runRecovery(
          (operation) => operation.recoverCopy(
            record.directory.path,
            folder: 'Same name',
            intentDigest: record.intentDigest,
            favorites: choices,
          ),
        );
        expect(result.succeeded, isFalse);
        expect(result.importedCount, 0);
        expect(
          result.issues.single.error.toString(),
          contains('Favorites changed'),
        );
        expect(manager.count, 0);
        expect(favorites.getFolderComics('Same name'), isEmpty);
        expect(ComicCopyRecord.exists(record.directory), isTrue);
      });
    },
  );

  test(
    'a changed copy intent cannot consume an earlier recovery decision',
    () async {
      final record = await pendingCopy(folder: 'Saved');
      final file = File(
        '${record.directory.path}/${ComicCopyRecord.intentName}',
      );
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      value['source'] = 'replacement intent';
      file.writeAsStringSync(jsonEncode(value));
      final result = await service.runRecovery(
        (operation) => operation.recoverCopy(
          record.directory.path,
          folder: null,
          intentDigest: record.intentDigest,
        ),
      );
      expect(result.succeeded, isFalse);
      expect(result.issues.single.error.toString(), contains('intent changed'));
      expect(manager.count, 0);
      expect(file.existsSync(), isTrue);
    },
  );

  test('copy metadata is detached before waiting for the worker', () async {
    final comic = comicIn('${root.path}/source', 'Captured');
    final result = await service.runImport((operation) {
      final result = operation.registerComics({
        null: [comic],
      }, copy: true);
      comic.tags.add('late tag');
      return result;
    });
    expect(result.importedCount, 1);
    expect(manager.findByName('Captured')!.tags, ['tag']);
  });

  test('copy imports a sibling whose path shares the library prefix', () async {
    final comic = comicIn('${manager.path}-external/Book', 'Sibling');
    expect(
      (await service.runImport(
        (operation) => operation.registerComics({
          null: [comic],
        }, copy: true),
      )).succeeded,
      isTrue,
    );
    final saved = manager.findByName(comic.title)!;
    expect(path.isWithin(manager.path, saved.directory), isTrue);
    expect(
      File(path.join(saved.directory, '1.jpg')).readAsStringSync(),
      'page',
    );
    expect(saved.subtitle, 'Author');
    expect(saved.tags, ['tag']);
    expect(saved.createdAt, comic.createdAt);
  });

  test(
    'copy does not redirect a registered comic to a new same-named source',
    () async {
      final original = comicIn('${manager.path}/Book', 'Original title');
      File('${original.directory}/1.jpg').writeAsStringSync('original pages');
      await manager.add(original, '1');
      final incoming = comicIn('${root.path}/external/Book', 'Incoming title');
      File('${incoming.directory}/1.jpg').writeAsStringSync('incoming pages');
      final result = await service.runImport(
        (operation) => operation.registerComics({
          null: [incoming],
        }, copy: true),
      );
      expect(result.importedCount, 1);
      final retained = manager.find('1', ComicType.local)!;
      expect(retained.directory, original.directory);
      expect(
        File(
          (await manager.getImages(
            '1',
            ComicType.local,
            1,
          )).single.replaceFirst('file://', ''),
        ).readAsStringSync(),
        'original pages',
      );
      final added = manager.findByName('Incoming title')!;
      expect(added.directory, isNot(original.directory));
      expect(
        File(
          (await manager.getImages(
            added.id,
            ComicType.local,
            1,
          )).single.replaceFirst('file://', ''),
        ).readAsStringSync(),
        'incoming pages',
      );
    },
  );

  test(
    'copy accepts immutable input and preserves the caller selection',
    () async {
      final comic = comicIn(
        path.join(root.path, 'external', 'Book'),
        'Immutable',
      );
      final comics = List<LocalComic>.unmodifiable([comic]);
      expect(
        (await service.runImport(
          (operation) => operation.registerComics({null: comics}, copy: true),
        )).succeeded,
        isTrue,
      );
      expect(comics.single, same(comic));
      expect(manager.findByName(comic.title), isNotNull);
      final recovered = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(recovered.importedCount, 0);
      expect(manager.count, 1);
    },
  );

  for (final relative in [false, true]) {
    test(
      'recovery recognizes recorded paths independently of titles; relative=$relative',
      () async {
        final directory = Directory('${manager.path}/storage-name')
          ..createSync();
        File('${directory.path}/1.jpg').writeAsStringSync('registered pages');
        await manager.add(
          LocalComic(
            id: '1',
            title: 'Different title',
            subtitle: '',
            tags: [],
            directory: relative ? directory.name : directory.path,
            chapters: null,
            cover: '1.jpg',
            comicType: ComicType.local,
            downloadedChapters: [],
            createdAt: DateTime(2024),
          ),
        );
        comicIn('${manager.path}/Recovered', 'Unused fixture title');
        final result = await service.runRecovery(
          (operation) => operation.localDownloads(isCancelled: () => false),
        );
        expect(result.importedCount, 1);
        expect(manager.count, 2);
        expect(manager.find('1', ComicType.local)!.title, 'Different title');
        expect(
          manager.getComics(LocalSortType.name).map((comic) => comic.title),
          unorderedEquals(['Different title', 'Recovered']),
        );
        expect(manager.findByName('Recovered'), isNotNull);
      },
    );
  }

  test(
    'copy failures cross the isolate boundary without losing successful members',
    () async {
      final good = comicIn('${root.path}/source/Good', 'Good');
      final bad = comicIn('${root.path}/source/Bad', 'Bad');
      File('${bad.directory}/1.jpg').writeAsBytesSync([]);
      final result = await service.runImport(
        (operation) => operation.registerComics({
          null: [good, bad],
        }, copy: true),
      );
      expect(result.succeeded, isTrue);
      expect(result.importedCount, 1);
      expect(manager.findByName('Good'), isNotNull);
      expect(manager.findByName('Bad'), isNull);
      final issue = result.issues.single;
      expect(issue.kind, ComicImportIssueKind.copyFailed);
      expect(issue.error, isA<ComicDirectoryCopyFailure>());
      final failure = issue.error! as ComicDirectoryCopyFailure;
      expect(failure.cause, isA<FileSystemException>());
      expect(failure.sourcePath, bad.directory);
      expect(failure.cleanupError, isNull);
      expect(failure.outputPath, isNotNull);
      expect(Directory(failure.outputPath!).existsSync(), isFalse);
      expect(failure.toString(), contains('Incomplete file read'));
      expect(issue.stackTrace, isNotNull);
      expect(File('${bad.directory}/1.jpg').existsSync(), isTrue);
    },
  );

  test(
    'directory scan preserves chapter order, skips invalid layouts and duplicates',
    () async {
      final source = Directory(path.join(root.path, 'selection'))..createSync();
      final book = Directory(path.join(source.path, 'Book'))..createSync();
      for (final chapter in ['10', '2']) {
        comicIn(path.join(book.path, chapter), 'unused');
      }
      comicIn(path.join(source.path, 'Invalid', 'chapter', 'nested'), 'unused');
      File(path.join(source.path, 'ignored.txt')).writeAsStringSync('ignored');
      final result = await service.runImport(
        (operation) => operation.directory(source, single: false, copy: true),
      );
      expect(result.succeeded, isTrue);
      expect(result.importedCount, 1);
      final saved = manager.findByName('Book')!;
      expect(saved.chapters!.ids, ['2', '10']);
      expect(
        await manager.getImages(saved.id, ComicType.local, 1),
        hasLength(1),
      );
      final repeated = await service.runImport(
        (operation) => operation.directory(book, single: true, copy: false),
      );
      expect(repeated.succeeded, isFalse);
      expect(repeated.issues.single.kind, ComicImportIssueKind.invalidComic);
      expect(manager.count, 1);
    },
  );

  test(
    'resolves the library after admission and keeps it throughout the operation',
    () async {
      final source = comicIn(path.join(root.path, 'Book'), 'Book');
      final gate = Completer<void>();
      final exclusive = manager.runWithExclusiveStorage(() => gate.future);
      var resolutions = 0;
      final injected = ComicImportService(
        localManager: () {
          resolutions++;
          if (resolutions > 1) throw StateError('Library resolver reused');
          return manager;
        },
        favoritesManager: () =>
            throw StateError('No favorite folder requested'),
      );
      final importing = injected.runImport((operation) async {
        await Future<void>.delayed(Duration.zero);
        return operation.directory(
          Directory(source.directory),
          single: true,
          copy: false,
        );
      });
      await pumpEventQueue();
      expect(resolutions, 0);
      gate.complete();
      await exclusive;
      expect((await importing).importedCount, 1);
      expect(resolutions, 1);
    },
  );

  test(
    'accepted import finishes while exit and data replacement wait',
    () async {
      final source = comicIn(path.join(root.path, 'Book'), 'Book');
      final admitted = Completer<void>();
      final gate = Completer<void>();
      final importing = service.runImport((operation) async {
        admitted.complete();
        await gate.future;
        return operation.directory(
          Directory(source.directory),
          single: true,
          copy: true,
        );
      });
      await admitted.future;
      var exitReady = false;
      final exiting = LocalComicStorageGuard.instance.prepareForExit().then((
        release,
      ) {
        exitReady = true;
        return release;
      });
      var replaced = false;
      final replacement = AppDataOperations.instance.run(() {
        expect(manager.findByName('Book'), isNotNull);
        replaced = true;
      });
      await pumpEventQueue();
      expect(exitReady, isFalse);
      expect(replaced, isFalse);
      gate.complete();
      try {
        expect((await importing).importedCount, 1);
        await replacement;
      } finally {
        (await exiting)();
      }
      expect(replaced, isTrue);
    },
  );

  test(
    'expired import handle cannot start another scan or registration',
    () async {
      late ComicImportOperation expired;
      await service.runImport((operation) async => expired = operation);
      final source = comicIn(path.join(root.path, 'Book'), 'Book');
      await expectLater(
        expired.directory(
          Directory(source.directory),
          single: true,
          copy: false,
        ),
        throwsStateError,
      );
      expect(
        () => expired.registerComics({
          null: [source],
        }, copy: false),
        throwsStateError,
      );
      expect(manager.count, 0);
    },
  );

  test(
    'cancelling recovery at scan completion does not register partial results',
    () async {
      comicIn(path.join(manager.path, 'Book'), 'Book');
      var cancelled = false;
      final result = await service.runRecovery(
        (operation) => operation.localDownloads(
          isCancelled: () => cancelled,
          onScanComplete: () => cancelled = true,
        ),
      );
      expect(result.succeeded, isFalse);
      expect(manager.count, 0);
      final recovered = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(recovered.importedCount, 1);
      expect(manager.findByName('Book')!.directory, 'Book');
    },
  );

  test(
    'ordinary imports cannot scan unfinished downloads as recovery',
    () async {
      await expectLater(
        service.runImport(
          (operation) => operation.localDownloads(isCancelled: () => false),
        ),
        throwsStateError,
      );
      expect(manager.count, 0);
    },
  );

  test(
    'partial registration reports the original failure and committed count',
    () async {
      await withFavorites((favorites) async {
        final first = comicIn(path.join(root.path, 'First'), 'First');
        final second = comicIn(path.join(root.path, 'Second'), 'Second');
        final result = await service.runImport(
          (operation) => operation.registerComics({
            null: [first],
            'Deleted folder': [second],
          }, copy: false),
        );
        expect(result.succeeded, isFalse);
        expect(result.importedCount, 1);
        expect(
          result.issues.single.kind,
          ComicImportIssueKind.registrationFailed,
        );
        expect(
          result.issues.single.error,
          isA<PersistenceFailure>()
              .having((error) => error.cause, "cause", isA<FormatException>())
              .having(
                (error) => error.commitState,
                "state",
                PersistenceCommitState.notCommitted,
              ),
        );
        expect(result.issues.single.stackTrace, isNotNull);
        expect(manager.findByName('First'), isNotNull);
        expect(manager.findByName('Second'), isNull);
        expect(File(path.join(second.directory, '1.jpg')).existsSync(), isTrue);
      });
    },
  );

  test(
    'EhViewer preserves quoted labels, default folder, metadata and borrowed files',
    () async {
      await withFavorites((favorites) async {
        final source = Directory(path.join(root.path, 'source'))..createSync();
        comicIn(path.join(source.path, 'first'), 'unused');
        comicIn(path.join(source.path, 'second'), 'unused');
        final dbFile = File(path.join(source.path, 'downloads.db'));
        final unrelatedCacheFile = File(path.join(App.cachePath, dbFile.name))
          ..writeAsStringSync('keep');
        final db = sqlite3.open(dbFile.path);
        try {
          db.execute('CREATE TABLE DOWNLOAD_LABELS (LABEL TEXT, TIME INT)');
          db.execute('CREATE TABLE DOWNLOAD_DIRNAME (GID INT, DIRNAME TEXT)');
          db.execute(
            'CREATE TABLE DOWNLOADS (GID INT, TITLE TEXT, TITLE_JPN TEXT, TIME INT, CATEGORY INT, LABEL TEXT, STATE INT)',
          );
          db.execute('INSERT INTO DOWNLOAD_LABELS VALUES (?, ?)', [
            "Reader's",
            1000,
          ]);
          db.execute('INSERT INTO DOWNLOAD_DIRNAME VALUES (1, ?), (2, ?)', [
            'first',
            'second',
          ]);
          db.execute(
            'INSERT INTO DOWNLOADS VALUES (1, ?, ?, 1000, 4, NULL, 3)',
            ['English', '日本語'],
          );
          db.execute(
            'INSERT INTO DOWNLOADS VALUES (2, ?, NULL, 2000, 2, ?, 3)',
            ['Second', "Reader's"],
          );
        } finally {
          db.dispose();
        }
        final result = await service.runImport(
          (operation) => operation.ehViewer(
            dbFile,
            source,
            defaultFolder: 'Localized default',
            copy: false,
            isCancelled: () => false,
          ),
        );
        expect(result.succeeded, isTrue);
        expect(result.issues, isEmpty);
        expect(result.importedCount, 2);
        final first = manager.findByName('日本語')!;
        expect(first.tags, ['MANGA']);
        expect(first.createdAt.millisecondsSinceEpoch, 1000);
        expect(favorites.find(first.id, ComicType.local), [
          'Localized default',
        ]);
        final second = manager.findByName('Second')!;
        expect(favorites.find(second.id, ComicType.local), [
          "(EhViewer)Reader's",
        ]);
        expect(unrelatedCacheFile.readAsStringSync(), 'keep');
        final reopened = sqlite3.open(dbFile.path);
        try {
          expect(reopened.select('SELECT * FROM DOWNLOADS'), hasLength(2));
        } finally {
          reopened.dispose();
        }
      });
    },
  );

  test(
    'archive batch keeps successful imports and reports failed members',
    () async {
      final source = Directory(path.join(root.path, 'archives'))..createSync();
      final contents = archive.Archive();
      final bytes = utf8.encode('page');
      contents.addFile(archive.ArchiveFile('1.jpg', bytes.length, bytes));
      File(
        path.join(source.path, 'Good.cbz'),
      ).writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
      File(
        path.join(source.path, 'Broken.cbz'),
      ).writeAsStringSync('invalid archive');
      File(path.join(source.path, 'ignored.txt')).writeAsStringSync('ignored');
      final result = await service.archives(source);
      expect(result.succeeded, isTrue);
      expect(result.importedCount, 1);
      expect(result.issues.single.kind, ComicImportIssueKind.archiveFailed);
      expect(result.issues.single.error, isNotNull);
      expect(result.issues.single.stackTrace, isNotNull);
      expect(manager.findByName('Good'), isNotNull);
      expect(manager.findByName('Broken'), isNull);
    },
  );
}
