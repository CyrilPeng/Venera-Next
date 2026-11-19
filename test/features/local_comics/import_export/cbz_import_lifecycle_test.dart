import 'package:venera_next/foundation/persistence_failure.dart';
import 'dart:convert';
import 'dart:async';
import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
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
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
    manager = LocalManager();
    await manager.init();
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.current?.dispose();
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

  File bookWithComicInfo(
    String name, {
    List<String> pages = const ['1.jpg', '2.jpg', '3.jpg'],
    String notes = 'Chapters: 第01卷: 1-2; 第02卷: 3-3',
    Map<String, Object?>? metadata,
    bool includeTitle = true,
    bool nested = false,
  }) {
    final contents = archive.Archive();
    final prefix = nested ? 'wrapped/' : '';
    final entries = {
      for (final page in pages) '$prefix$page': page,
      if (metadata != null) '${prefix}metadata.json': jsonEncode(metadata),
      '${prefix}ComicInfo.xml':
          '<ComicInfo>${includeTitle ? '<Title>$name</Title>' : ''}'
          '<Writer>Author</Writer><Genre>Action, Adventure</Genre>'
          '<Tags>fantasy</Tags><Notes>$notes</Notes></ComicInfo>',
    };
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      contents.addFile(archive.ArchiveFile(entry.key, bytes.length, bytes));
    }
    return File('${root.path}/$name.cbz')
      ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
  }

  Future<LocalComic> importBook(File input) =>
      CBZ.import(input, registerComic: (comic) => manager.add(comic, comic.id));

  Future<void> expectAllPages(LocalComic comic, List<String> pages) async {
    final imageUris = <String>[];
    if (comic.chapters == null) {
      imageUris.addAll(await manager.getImages(comic.id, ComicType.local, 1));
    } else {
      for (final chapter in comic.downloadedChapters) {
        imageUris.addAll(
          await manager.getImages(comic.id, ComicType.local, chapter),
        );
      }
    }
    expect(
      [
        for (final uri in imageUris)
          File(CBZ.localFilePathFromImageUri(uri)).readAsStringSync(),
      ],
      pages,
      reason: 'Every source page must remain readable in its original order',
    );
  }

  test(
    'flat CBZ carrying only ComicInfo.xml restores chapters on import',
    () async {
      final service = ComicImportService(
        localManager: () => manager,
        favoritesManager: LocalFavoritesManager.new,
      );
      await CBZ.import(
        bookWithComicInfo('ComicInfoBook'),
        registerComic: service.registerComic,
      );
      final saved = manager.findByName('ComicInfoBook')!;
      expect(saved.hasChapters, isTrue);
      expect(saved.chapters!.titles.toList(), ['第01卷', '第02卷']);
      expect(saved.chapters!.ids.toList(), ['0', '1']);
      expect(saved.downloadedChapters, ['0', '1']);
      // Cover inferred from the first root page when no explicit cover exists.
      final coverPath = '${manager.path}/${saved.directory}/${saved.cover}';
      expect(File(coverPath).existsSync(), isTrue);
      // Chapter pages are copied into per-chapter directories.
      final chapter1 = await manager.getImages(saved.id, ComicType.local, '0');
      expect(chapter1, hasLength(2));
      final chapter2 = await manager.getImages(saved.id, ComicType.local, '1');
      expect(chapter2, hasLength(1));
      expect(saved.subtitle, 'Author');
      expect(saved.tags, ['Action', 'Adventure', 'fantasy']);
      await expectAllPages(saved, ['1.jpg', '2.jpg', '3.jpg']);
    },
  );

  for (final withMetadata in [false, true]) {
    test(
      'real chapter folders take precedence over XML ranges; JSON=$withMetadata',
      () async {
        const pages = ['Ch1/1.jpg', 'Ch2/1.jpg'];
        final input = bookWithComicInfo(
          'Directories',
          pages: pages,
          notes: 'Chapters: XML one: 1-1; XML two: 2-2',
          nested: true,
          metadata: withMetadata
              ? {
                  'title': 'Directories',
                  'author': 'JSON Author',
                  'tags': ['JSON tag'],
                }
              : null,
        );
        final comic = await importBook(input);
        expect(comic.chapters!.titles.toList(), ['Ch1', 'Ch2']);
        expect(comic.chapters!.ids.toList(), ['0', '1']);
        expect(comic.downloadedChapters, ['0', '1']);
        expect(comic.coverFile.readAsStringSync(), pages.first);
        expect(comic.subtitle, withMetadata ? 'JSON Author' : 'Author');
        await expectAllPages(comic, pages);
        expect(input.existsSync(), isTrue);
        expect(Directory(App.cachePath).listSync(), isEmpty);
      },
    );
  }

  for (final invalid in [
    ('missing first pages', 'Chapters: Extra: 3-4'),
    ('missing middle page', 'Chapters: First: 1-1; Last: 3-4'),
    ('missing last pages', 'Chapters: First: 1-2'),
    ('beyond page count', 'Chapters: Whole: 1-5'),
  ]) {
    test('XML ranges ${invalid.$1} fall back without losing pages', () async {
      const pages = ['1.jpg', '2.jpg', '3.jpg', '4.jpg'];
      final input = bookWithComicInfo(
        'Fallback',
        pages: pages,
        notes: invalid.$2,
      );
      final comic = await importBook(input);
      expect(comic.hasChapters, isFalse);
      expect(comic.title, 'Fallback');
      expect(comic.subtitle, 'Author');
      expect(comic.tags, ['Action', 'Adventure', 'fantasy']);
      await expectAllPages(comic, pages);
      expect(input.existsSync(), isTrue);
      expect(Directory(App.cachePath).listSync(), isEmpty);
    });
  }

  test(
    'duplicate XML chapter titles keep distinct IDs and all pages',
    () async {
      const pages = ['1.jpg', '2.jpg', '3.jpg', '4.jpg'];
      final input = bookWithComicInfo(
        'Duplicate',
        pages: pages,
        notes: 'Chapters: Part: 1-2; Part: 3-4',
      );
      final comic = await importBook(input);
      expect(comic.chapters!.titles.toList(), ['Part', 'Part']);
      expect(comic.chapters!.ids.toList(), ['0', '1']);
      expect(comic.downloadedChapters, ['0', '1']);
      await expectAllPages(comic, pages);
      expect(input.existsSync(), isTrue);
    },
  );

  for (final withJsonChapters in [false, true]) {
    test(
      'JSON metadata keeps precedence; own chapters=$withJsonChapters',
      () async {
        const pages = ['1.jpg', '2.jpg', '3.jpg', '4.jpg'];
        final input = bookWithComicInfo(
          'XML title',
          pages: pages,
          notes: 'Chapters: XML chapter: 1-4',
          metadata: {
            'title': 'JSON title',
            'author': 'JSON Author',
            'tags': ['JSON tag'],
            if (withJsonChapters)
              'chapters': [
                {'title': 'Part', 'start': 1, 'end': 2},
                {'title': 'Part', 'start': 3, 'end': 4},
              ]
            else
              'chapters': <Object>[],
          },
        );
        final comic = await importBook(input);
        expect(comic.title, 'JSON title');
        expect(comic.subtitle, 'JSON Author');
        expect(comic.tags, ['JSON tag']);
        expect(
          comic.chapters!.titles.toList(),
          withJsonChapters ? ['Part', 'Part'] : ['XML chapter'],
        );
        expect(
          comic.chapters!.ids.toList(),
          withJsonChapters ? ['0', '1'] : ['0'],
        );
        await expectAllPages(comic, pages);
        expect(input.existsSync(), isTrue);
      },
    );
  }

  test(
    'XML notes restore chapters when the archive supplies the title',
    () async {
      final input = bookWithComicInfo('Filename title', includeTitle: false);
      final comic = await importBook(input);
      expect(comic.title, 'Filename title');
      expect(comic.chapters!.titles.toList(), ['第01卷', '第02卷']);
      await expectAllPages(comic, ['1.jpg', '2.jpg', '3.jpg']);
      expect(input.existsSync(), isTrue);
    },
  );

  for (final name in [
    '[Sample Artist \u2013 V.24 black and white part01 (53p).zip].zip',
    'Sample24.zip',
    '[Sample Artist .25 in the camping car part02 (51p).zip].zip',
  ]) {
    test(
      'archive display name $name stays visible and readable after reopening',
      () async {
        final contents = archive.Archive();
        for (final page in ['2.jpg', '1.jpg']) {
          final bytes = utf8.encode(page);
          contents.addFile(archive.ArchiveFile(page, bytes.length, bytes));
        }
        final input = File('${root.path}/$name')
          ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
        final service = ComicImportService(
          localManager: () => manager,
          favoritesManager: LocalFavoritesManager.new,
        );
        await CBZ.import(input, registerComic: service.registerComic);
        final title = name.substring(0, name.lastIndexOf('.'));
        Future<void> readable() async {
          final saved = manager.getComics(LocalSortType.name).single;
          expect(saved.title, title);
          expect(manager.findByName(title), isNotNull);
          expect(saved.coverFile.readAsStringSync(), '1.jpg');
          final images = await manager.getImages(saved.id, ComicType.local, 1);
          expect(images, hasLength(2));
          expect(
            File(images.first.replaceFirst('file://', '')).readAsStringSync(),
            '1.jpg',
          );
        }

        await readable();
        await manager.pendingDownloadTaskWrites;
        manager.dispose();
        manager = LocalManager(initializeSources: () async {});
        await manager.init();
        await readable();
        expect(input.existsSync(), isTrue);
      },
    );
  }

  test(
    'WebDAV restore keeps the real archive importer guarded until registration',
    () async {
      final gate = Completer<void>();
      final registering = Completer<void>();
      final backup = ComicBackupManager(
        operations: _ArchiveDownloadOps(book('Restored')),
        readConfig: _backupConfig,
        registerImportedComic: (comic) async {
          registering.complete();
          await gate.future;
          await manager.add(comic, comic.id);
        },
      );
      final restoring = backup.restore([
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
      final error = StateError('restore acknowledgement failed');
      var registrations = 0;
      final backup = ComicBackupManager(
        operations: _ArchiveDownloadOps(book('Restored')),
        readConfig: _backupConfig,
        registerImportedComic: (comic) async {
          registrations++;
          await manager.add(comic, comic.id);
          throw error;
        },
      );
      final batch = backup.createRestoreBatch([
        BackupFile(name: 'Restored.cbz', size: 1, modified: DateTime(2024)),
      ]);
      addTearDown(batch.dispose);
      await batch.run();
      final result = BackupResult.fromBatch(batch);
      expect(result.success, 0);
      expect(result.failed, 1);
      expect(batch.items.single.canRetry, isFalse);
      await batch.run(retryFailed: true);
      await batch.run();
      expect(registrations, 1);
      expect(manager.getComics(LocalSortType.name), hasLength(1));
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

BackupConfig _backupConfig() => BackupConfig(
  url: 'https://backup.example.test',
  user: 'test',
  pass: 'test',
  remotePath: '/backup',
);

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
