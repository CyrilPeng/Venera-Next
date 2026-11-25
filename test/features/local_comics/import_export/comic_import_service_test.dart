import 'legacy_copy_fixture.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive_io.dart' as archive;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_metadata.dart';
import 'package:venera_next/features/local_comics/import_export/comic_copy_record.dart';
import 'package:venera_next/features/local_comics/import_export/comic_directory_copy.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/local_comics/import_export/comic_collection_archive.dart';
import 'package:venera_next/features/local_comics/import_export/comic_export_service.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/import_export/comic_archive_compressor.dart';
import 'package:image/image.dart' as image;
import 'package:venera_next/foundation/selection_operation.dart';
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
    final favorites = LocalFavoritesManager();
    try {
      await favorites.init();
      await action(favorites);
    } finally {
      await favorites.debugWaitForHashedIdsRefresh();
      await appdata.saveData(false);
      favorites.close();
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

  List<int> zip(Map<String, List<int>> files) {
    final contents = archive.Archive();
    for (final entry in files.entries) {
      contents.addFile(archive.ArchiveFile.bytes(entry.key, entry.value));
    }
    return archive.ZipEncoder().encodeBytes(contents);
  }

  List<int> bookBytes(String title) => zip({
    '1.jpg': utf8.encode('page of $title'),
    'metadata.json': utf8.encode(
      jsonEncode({
        'title': title,
        'author': 'Author',
        'tags': ['tag'],
      }),
    ),
  });

  File collection(Map<String, List<int>> books) =>
      File(path.join(root.path, 'comics_export.zip'))
        ..writeAsBytesSync(zip(books));

  testWidgets('real multiple-CBZ export imports metadata, chapters and pages', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final first = comicIn('${root.path}/source/first', '漫画 One');
      final chaptered = comicIn('${root.path}/source/second', 'Book Two');
      final pageBytes = [
        for (var index = 0; index < 3; index++)
          image.encodeJpg(
            image.Image(width: 32, height: 32)
              ..setPixelRgb(0, 0, index * 80, 100, 20),
          ),
      ];
      File('${first.directory}/1.jpg').writeAsBytesSync(pageBytes[0]);
      File('${chaptered.directory}/1.jpg').writeAsBytesSync(pageBytes[1]);
      var chapterIndex = 1;
      for (final chapter in ['first', 'second']) {
        final directory = Directory('${chaptered.directory}/$chapter')
          ..createSync();
        File(
          '${directory.path}/1.jpg',
        ).writeAsBytesSync(pageBytes[chapterIndex++]);
      }
      final second = LocalComic(
        id: '0',
        title: chaptered.title,
        subtitle: chaptered.subtitle,
        tags: chaptered.tags,
        directory: chaptered.directory,
        chapters: const ComicChapters({'first': '第一章', 'second': '第二章'}),
        cover: '1.jpg',
        comicType: ComicType.local,
        downloadedChapters: ['first', 'second'],
        createdAt: chaptered.createdAt,
      );
      await service.registerComic(first);
      await service.registerComic(second);
      final original = manager.getComics(LocalSortType.name).toList();
      final exported = File('${root.path}/roundtrip.zip');
      await SelectionOperation().run(
        (operation) => exportLocalComics(
          original,
          operation: operation,
          cachePath: root.path,
          extension: '.cbz',
          export: CBZ.export,
          compress: compressComicArchive,
          save: (file, name) async {
            expect(name, 'comics_export.zip');
            await file.copy(exported.path);
          },
          isCancelled: () => false,
        ),
      );
      await manager.pendingDownloadTaskWrites;
      manager.dispose();
      App.dataPath = (Directory('${root.path}/restored')..createSync()).path;
      manager = LocalManager(initializeSources: () async {});
      await manager.init();
      final result = await service.archive(exported);
      expect(
        result.issues,
        isEmpty,
        reason: result.issues
            .map((issue) => '${issue.sourceName}: ${issue.error}')
            .join('\n'),
      );
      expect(result.importedCount, 2);
      for (final source in original) {
        final saved = manager.findByName(source.title)!;
        expect(saved.subtitle, source.subtitle);
        expect(saved.tags, source.tags);
        expect(saved.chapters?.titles, source.chapters?.titles);
        final chapters = saved.downloadedChapters.isEmpty
            ? <dynamic>[1]
            : saved.downloadedChapters;
        final pages = <List<int>>[];
        for (final chapter in chapters) {
          for (final uri in await manager.getImages(
            saved.id,
            ComicType.local,
            chapter,
          )) {
            pages.add(
              File(CBZ.localFilePathFromImageUri(uri)).readAsBytesSync(),
            );
          }
        }
        expect(
          pages,
          source.chapters == null
              ? [pageBytes[0]]
              : [pageBytes[1], pageBytes[2]],
        );
      }
      expect(exported.existsSync(), isTrue);
      expect(File('${first.directory}/1.jpg').readAsBytesSync(), pageBytes[0]);
      expect(
        root.listSync().where((entry) => entry.name.startsWith('cbz_')),
        isEmpty,
      );
    });
  });

  for (final wrapper in ['', 'Collection/']) {
    test('single archive imports each wrapped CBZ: $wrapper', () async {
      final source = collection({
        '${wrapper}Book 10.cbz': bookBytes('Ten'),
        '${wrapper}Book 2.cbz': bookBytes('Two'),
        '__MACOSX/._Book.cbz': [1],
      });
      final result = await service.archive(source);
      expect(result.importedCount, 2);
      expect(result.issues, isEmpty);
      expect(manager.findByName('Ten')!.tags, ['tag']);
      expect(manager.findByName('Two')!.subtitle, 'Author');
      expect(source.existsSync(), isTrue);
    });
  }

  test(
    'collection keeps successes and reports damaged and duplicate children',
    () async {
      await service.registerComic(
        comicIn('${root.path}/existing', 'Duplicate'),
      );
      final source = collection({
        '1 Good.cbz': bookBytes('Good'),
        '2 Broken.cbz': utf8.encode('broken'),
        '3 Duplicate.cbz': bookBytes('Duplicate'),
        '4 Last.cbz': bookBytes('Last'),
      });
      final result = await service.archive(source);
      expect(result.succeeded, isTrue);
      expect(result.importedCount, 2);
      expect(result.issues.map((issue) => issue.sourceName), [
        'comics_export.zip / 2 Broken.cbz',
        'comics_export.zip / 3 Duplicate.cbz',
      ]);
      expect(manager.count, 3);
      expect(source.existsSync(), isTrue);
      expect(
        root.listSync().where((entry) => entry.name.startsWith('cbz_')),
        isEmpty,
      );
    },
  );

  test(
    'archive directory counts collection children and ordinary CBZs',
    () async {
      final directory = Directory('${root.path}/batch')..createSync();
      final source = collection({
        'A.cbz': bookBytes('A'),
        'B.cbz': bookBytes('B'),
      });
      await source.copy('${directory.path}/collection.zip');
      File('${directory.path}/C.cbz').writeAsBytesSync(bookBytes('C'));
      final result = await service.archives(directory);
      expect(result.importedCount, 3);
      expect(result.issues, isEmpty);
      expect(manager.count, 3);
    },
  );

  for (final byteBudget in [false, true]) {
    test(
      'collection expansion limits accumulate across both layers: bytes=$byteBudget',
      () async {
        final first = bookBytes('First');
        final second = bookBytes('Second');
        final source = collection({'1.cbz': first, '2.cbz': second});
        final firstFile = File('${root.path}/first.cbz')
          ..writeAsBytesSync(first);
        final index = await inspectComicArchive(firstFile);
        final result = await service.archive(
          source,
          limits: byteBudget
              ? ComicArchiveLimits(
                  maxExpandedBytes:
                      first.length + second.length + index.expandedBytes,
                )
              : const ComicArchiveLimits(maxEntries: 5),
        );
        expect(result.importedCount, 1);
        expect(result.issues.single.sourceName, 'comics_export.zip / 2.cbz');
        expect(
          result.issues.single.error.toString(),
          contains('import limits'),
        );
        expect(manager.findByName('First'), isNotNull);
        expect(manager.findByName('Second'), isNull);
      },
    );
  }

  test('collection comic count is limited before extraction', () async {
    final source = collection({
      'A.cbz': bookBytes('A'),
      'B.cbz': bookBytes('B'),
    });
    final result = await service.archive(
      source,
      limits: const ComicArchiveLimits(maxComics: 1),
    );
    expect(result.importedCount, 0);
    expect(result.issues.single.error.toString(), contains('import limits'));
    expect(manager.directory.listSync(), isEmpty);
  });

  for (final batch in [false, true]) {
    test(
      'cancelling between children preserves committed books and cleans staging: batch=$batch',
      () async {
        final source = collection({
          '1.cbz': bookBytes('First'),
          '2.cbz': bookBytes('Second'),
        });
        void checkStop() {
          if (manager.count == 1) throw const SelectionCancelled();
        }

        await expectLater(
          batch
              ? service.archives(root, checkStop: checkStop)
              : service.archive(source, checkStop: checkStop),
          throwsA(isA<SelectionCancelled>()),
        );
        expect(manager.findByName('First'), isNotNull);
        expect(manager.findByName('Second'), isNull);
        expect(source.existsSync(), isTrue);
        expect(
          root.listSync().where((entry) => entry.name.startsWith('cbz_')),
          isEmpty,
        );
      },
    );
  }

  for (final wrapper in ['', 'Book/']) {
    test('ordinary chapter ZIP stays one comic: wrapper=$wrapper', () async {
      final source = File('${root.path}/Chaptered.zip')
        ..writeAsBytesSync(
          zip({
            '${wrapper}Chapter 1/1.jpg': utf8.encode('first chapter page'),
            '${wrapper}Chapter 2/1.jpg': utf8.encode('second chapter page'),
          }),
        );
      final result = await service.archive(source);
      expect(result.importedCount, 1);
      expect(result.issues, isEmpty);
      expect(manager.findByName('Chaptered')!.chapters!.titles, [
        'Chapter 1',
        'Chapter 2',
      ]);
      expect(manager.count, 1);
    });
  }

  test('nested containers are not recursively imported', () async {
    final source = collection({
      'Nested.cbz': zip({'Book.cbz': bookBytes('Book')}),
    });
    final result = await service.archive(source);
    expect(result.importedCount, 0);
    expect(result.issues.single.error.toString(), contains('No images'));
    expect(manager.count, 0);
  });

  for (final damaged in [false, true]) {
    test(
      'unsafe or CRC-damaged inner CBZ cannot escape collection staging: damaged=$damaged',
      () async {
        List<int> inner;
        if (damaged) {
          final archiveFile = archive.Archive()
            ..addFile(
              archive.ArchiveFile.noCompress('1.jpg', 4, [71, 72, 73, 74]),
            );
          inner = archive.ZipEncoder().encodeBytes(archiveFile);
          final nameLength = inner[26] | inner[27] << 8;
          final extraLength = inner[28] | inner[29] << 8;
          inner[30 + nameLength + extraLength] = 70;
        } else {
          inner = zip({
            '../escape.jpg': [1, 2],
          });
        }
        final source = collection({
          '1 Good.cbz': bookBytes('Good'),
          '2 Broken.cbz': inner,
        });
        final result = await service.archive(source);
        expect(result.importedCount, 1);
        expect(
          result.issues.single.sourceName,
          'comics_export.zip / 2 Broken.cbz',
        );
        expect(
          result.issues.single.error.toString(),
          contains(damaged ? 'damaged file data' : 'unsafe path'),
        );
        expect(manager.findByName('Good'), isNotNull);
        expect(File('${root.path}/escape.jpg').existsSync(), isFalse);
        expect(
          root.listSync().where((entry) => entry.name.startsWith('cbz_')),
          isEmpty,
        );
      },
    );
  }

  for (final failRead in [false, true]) {
    test(
      'directory worker drains progress before registration; failRead=$failRead',
      () async {
        final source = Directory('${root.path}/progress-source')..createSync();
        for (var index = 0; index < 8; index++) {
          File(
            '${source.path}/$index.jpg',
          ).writeAsStringSync(failRead && index == 0 ? '' : 'page $index');
        }
        final progress = <ComicDirectoryCopyProgress>[];
        var registering = false;
        final result = await service.runImport(
          (operation) => operation.directory(
            source,
            single: true,
            copy: true,
            onCopyProgress: (update) {
              expect(registering, isFalse);
              expect(manager.count, 0);
              expect(update.sourcePath, source.path);
              progress.add(update);
            },
            onRegistering: () {
              registering = true;
              expect(manager.count, 0);
              if (!failRead) {
                expect(progress.last.stage, ComicCopyStage.verifying);
                expect(progress.last.processed, 8);
                expect(progress.last.total, 8);
              }
            },
          ),
        );
        expect(registering, isTrue);
        expect(result.importedCount, failRead ? 0 : 1);
        expect(source.listSync(), hasLength(8));
        if (failRead) {
          expect(result.issues.single.kind, ComicImportIssueKind.copyFailed);
          expect(manager.directory.listSync(), isEmpty);
        } else {
          expect(result.issues, isEmpty);
          expect(
            progress.map((update) => update.stage).toSet(),
            ComicCopyStage.values.toSet(),
          );
          final saved = manager.findByName(source.name)!;
          expect(ComicCopyRecord.exists(Directory(saved.directory)), isFalse);
          expect(Directory(saved.directory).listSync(), hasLength(8));
        }
      },
    );
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
    'incomplete legacy copy is preserved and unmarked comics need confirmation',
    () async {
      final source = comicIn('${root.path}/source', 'Unfinished');
      final partial = Directory('${manager.path}/partial')..createSync();
      prepareLegacyComicCopy(
        partial,
        source: source.directory,
        metadata: encodeComicCopyMetadata(source, null),
      );
      File('${partial.path}/1.jpg').writeAsStringSync('first of three pages');
      comicIn('${manager.path}/Legacy', 'unused');
      final result = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(result.importedCount, 0);
      expect(
        result.issues.single.kind,
        ComicImportIssueKind.copyRecoveryRequired,
      );
      expect(manager.findByName('Unfinished'), isNull);
      expect(manager.findByName('Legacy'), isNull);
      final pending = result.pendingCopies.single;
      expect(pending.kind, ComicCopyRecoveryKind.unverified);
      final recovered = await service.runRecovery(
        (operation) => operation.recoverCopy(pending, folder: null),
      );
      expect(recovered.importedCount, 1);
      expect(manager.findByName('Legacy'), isNotNull);
      expect(
        File('${partial.path}/1.jpg').readAsStringSync(),
        'first of three pages',
      );
      expect(ComicCopyRecord.exists(partial), isTrue);
    },
  );

  test(
    'recovery resumes a version 2 copy before registering its original metadata',
    () async {
      final source = comicIn('${root.path}/source', 'Interrupted title');
      File('${source.directory}/2.jpg').writeAsStringSync('second');
      final partial = Directory('${manager.path}/partial')..createSync();
      await ComicCopyRecord.prepare(
        partial,
        source: Directory(source.directory),
        metadata: encodeComicCopyMetadata(source, null),
      );
      File('${partial.path}/1.jpg').writeAsStringSync('page');
      final scanned = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      expect(scanned.importedCount, 0);
      expect(scanned.issues, isEmpty);
      final pending = scanned.pendingCopies.single;
      expect(pending.kind, ComicCopyRecoveryKind.resumable);
      final recovered = await service.runRecovery(
        (operation) => operation.recoverCopy(pending, folder: null),
      );
      expect(recovered.importedCount, 1);
      expect(manager.findByName('Interrupted title')!.subtitle, 'Author');
      expect(File('${partial.path}/2.jpg').readAsStringSync(), 'second');
      expect(ComicCopyRecord.exists(partial), isFalse);
      expect(
        (await service.runRecovery(
          (operation) => operation.recoverCopy(pending, folder: null),
        )).importedCount,
        0,
      );
      expect(manager.count, 1);
    },
  );

  test(
    'legacy confirmation cannot accept files changed after the scan',
    () async {
      final comic = comicIn('${manager.path}/Legacy', 'unused');
      final scanned = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      final pending = scanned.pendingCopies.single;
      File('${comic.directory}/2.jpg').writeAsStringSync('new page');
      final result = await service.runRecovery(
        (operation) => operation.recoverCopy(pending, folder: null),
      );
      expect(result.succeeded, isFalse);
      expect(manager.count, 0);
      expect(File('${comic.directory}/2.jpg').readAsStringSync(), 'new page');
    },
  );

  test(
    'a library replacement invalidates an earlier recovery decision',
    () async {
      comicIn('${manager.path}/Legacy', 'unused');
      final scanned = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      final pending = scanned.pendingCopies.single;
      manager.dispose();
      manager = LocalManager(initializeSources: () async {});
      await manager.init();
      final result = await service.runRecovery(
        (operation) => operation.recoverCopy(pending, folder: null),
      );
      expect(result.succeeded, isFalse);
      expect(
        result.issues.single.error.toString(),
        contains('Local library changed'),
      );
      expect(manager.count, 0);
      expect(File('${pending.directory}/1.jpg').readAsStringSync(), 'page');
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
              scanned.pendingCopies.single,
              folder: localOnly ? null : 'Current choice',
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
        final scanned = await service.runRecovery(
          (operation) => operation.localDownloads(isCancelled: () => false),
        );
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
            scanned.pendingCopies.single,
            folder: 'Same name',
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
      final scanned = await service.runRecovery(
        (operation) => operation.localDownloads(isCancelled: () => false),
      );
      final file = File(
        '${record.directory.path}/${ComicCopyRecord.intentName}',
      );
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      value['source'] = 'replacement intent';
      file.writeAsStringSync(jsonEncode(value));
      final result = await service.runRecovery(
        (operation) =>
            operation.recoverCopy(scanned.pendingCopies.single, folder: null),
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
        expect(result.importedCount, 0);
        expect(manager.count, 1);
        final restored = await service.runRecovery(
          (operation) =>
              operation.recoverCopy(result.pendingCopies.single, folder: null),
        );
        expect(restored.importedCount, 1);
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
      expect(recovered.importedCount, 0);
      expect(recovered.pendingCopies.single.title, 'Book');
      expect(manager.findByName('Book'), isNull);
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
      expect(result.issues.single.sourceName, 'Broken.cbz');
      expect(result.issues.single.error, isNotNull);
      expect(result.issues.single.stackTrace, isNotNull);
      expect(manager.findByName('Good'), isNotNull);
      expect(manager.findByName('Broken'), isNull);
    },
  );

  for (final hasBrokenArchive in [false, true]) {
    test(
      'archive batch with no successful imports is not a success; broken=$hasBrokenArchive',
      () async {
        final source = Directory(path.join(root.path, 'archives'))
          ..createSync();
        if (hasBrokenArchive) {
          File(
            path.join(source.path, 'Broken.zip'),
          ).writeAsStringSync('invalid archive');
        }
        final result = await service.archives(source);
        expect(result.succeeded, isFalse);
        expect(result.importedCount, 0);
        expect(
          result.issues.map((issue) => issue.kind),
          contains(ComicImportIssueKind.noValidComics),
        );
        expect(manager.count, 0);
        if (hasBrokenArchive) {
          final failure = result.issues.first;
          expect(failure.sourceName, 'Broken.zip');
          expect(failure.error, isNotNull);
        }
      },
    );
  }
}
