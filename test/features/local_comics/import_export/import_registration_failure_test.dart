import 'dart:convert';
import 'dart:async';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/import_export/epub_import.dart';
import 'package:venera_next/features/local_comics/import_export/pdf_import.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/features/favorites/favorites_api.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_output.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const service = ComicImportService(
    localManager: LocalManager.new,
    favoritesManager: LocalFavoritesManager.new,
  );
  late Directory root;
  late LocalManager manager;
  late LocalFavoritesManager favorites;
  Object? oldFollow;
  Object? oldQuick;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('registration-failure-');
    App.dataPath = root.path;
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    oldFollow = appdata.settings['followUpdatesFolder'];
    oldQuick = appdata.settings['quickFavorite'];
    LocalFavoritesManager.cache = null;
    favorites = LocalFavoritesManager();
    await favorites.init();
    await favorites.createFolder('Imports');
  });

  tearDown(() async {
    await favorites.debugWaitForHashedIdsRefresh();
    await appdata.saveData(false);
    favorites.close();
    LocalFavoritesManager.cache = null;
    appdata.settings['followUpdatesFolder'] = oldFollow;
    appdata.settings['quickFavorite'] = oldQuick;
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  void execute(String database, String statement) {
    final db = sqlite3.open('${root.path}/$database');
    try {
      db.execute(statement);
    } finally {
      db.dispose();
    }
  }

  File archiveInput(String format) {
    final contents = archive.Archive();
    final entries = format == 'epub'
        ? {
            'META-INF/container.xml':
                '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
            'book.opf':
                '<package><metadata><title>Book</title></metadata><manifest><item id="page" href="1.jpg" media-type="image/jpeg"/></manifest><spine><itemref idref="page"/></spine></package>',
            '1.jpg': 'page',
          }
        : {'1.jpg': 'page'};
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      contents.addFile(archive.ArchiveFile(entry.key, bytes.length, bytes));
    }
    return File('${root.path}/Book.$format')
      ..writeAsBytesSync(archive.ZipEncoder().encodeBytes(contents));
  }

  Future<LocalComic> import(
    String format,
    Future<void> Function(LocalComic) register,
  ) => switch (format) {
    'pdf' => PdfComicImporter.importDocument(
      _Document(),
      title: 'Book',
      registerComic: register,
    ),
    'epub' => EpubComicImporter.import(
      archiveInput(format),
      registerComic: register,
    ),
    _ => CBZ.import(archiveInput(format), registerComic: register),
  };

  for (final format in ['pdf', 'epub', 'cbz']) {
    test(
      '$format cleans a confirmed local INSERT rollback and permits retry',
      () async {
        execute('local.db', '''
        CREATE TRIGGER reject_insert BEFORE INSERT ON comics
        BEGIN SELECT RAISE(ABORT, 'local insert failure'); END;
      ''');
        await expectLater(
          import(format, service.registerComic),
          throwsA(
            isA<PersistenceFailure>()
                .having(
                  (error) => error.commitState,
                  'state',
                  PersistenceCommitState.notCommitted,
                )
                .having(
                  (error) => error.cause.toString(),
                  'cause',
                  contains('local insert failure'),
                ),
          ),
        );
        expect(manager.count, 0);
        expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        execute('local.db', 'DROP TRIGGER reject_insert');
        await import(format, service.registerComic);
        expect(manager.findByName('Book')!.id, '1');
      },
    );
    for (final committed in [false, true]) {
      test(
        '$format retains a saved callback failure; classified=$committed',
        () async {
          final original = StateError('acknowledgement failed');
          final stack = StackTrace.current;
          final failure = committed
              ? PersistenceFailure(
                  commitState: PersistenceCommitState.committed,
                  cause: original,
                  stackTrace: stack,
                )
              : original;
          await expectLater(
            import(format, (comic) async {
              await manager.add(comic, comic.id);
              Error.throwWithStackTrace(failure, stack);
            }),
            throwsA(
              isA<PersistenceFailure>()
                  .having((error) => error.cause, 'cause', same(original))
                  .having(
                    (error) => error.stackTrace.toString(),
                    'stack',
                    stack.toString(),
                  )
                  .having(
                    (error) => error.commitState,
                    'state',
                    committed
                        ? PersistenceCommitState.committed
                        : PersistenceCommitState.unknown,
                  ),
            ),
          );
          final saved = manager.findByName('Book')!;
          expect(
            File(
              '${manager.path}/${saved.directory}/${saved.cover}',
            ).existsSync(),
            isTrue,
          );
          expect(Directory(App.cachePath).listSync(), isEmpty);
        },
      );
    }
    test(
      '$format rolls back both stores even when legacy compensation would fail',
      () async {
        execute('local_favorite.db', '''
        CREATE TRIGGER reject_favorite BEFORE INSERT ON "Imports"
        BEGIN SELECT RAISE(ABORT, 'original favorite failure'); END;
      ''');
        execute('local.db', '''
        CREATE TRIGGER reject_compensation BEFORE DELETE ON comics
        BEGIN SELECT RAISE(ABORT, 'local compensation failure'); END;
      ''');
        Object? failure;
        try {
          await import(
            format,
            (comic) => service.registerComic(comic, folder: 'Imports'),
          );
        } catch (error) {
          failure = error;
        }
        expect(manager.findByName('Book'), isNull);
        expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        expect(favorites.getFolderComics('Imports'), isEmpty);
        expect(failure, isA<PersistenceFailure>());
        final persistence = failure! as PersistenceFailure;
        expect(persistence.commitState, PersistenceCommitState.notCommitted);
        expect(
          persistence.cause.toString(),
          contains('original favorite failure'),
        );
        expect(persistence.cleanupFailures, isEmpty);
        expect(Directory(App.cachePath).listSync(), isEmpty);
      },
    );
  }
  for (final format in ['pdf', 'epub', 'cbz']) {
    test(
      '$format retains both records after a favorite publication failure',
      () async {
        final original = StateError('favorite acknowledgement failed');
        final stack = StackTrace.current;
        final injected = ComicImportService(
          localManager: () => manager,
          favoritesManager: () =>
              _FavoritesAfterWrite(favorites, original, stack),
        );
        await expectLater(
          import(
            format,
            (comic) => injected.registerComic(comic, folder: 'Imports'),
          ),
          throwsA(
            isA<PersistenceFailure>()
                .having((error) => error.cause, 'cause', same(original))
                .having(
                  (error) => error.stackTrace.toString(),
                  'stack',
                  stack.toString(),
                )
                .having(
                  (error) => error.commitState,
                  'state',
                  PersistenceCommitState.committed,
                ),
          ),
        );
        final saved = manager.findByName('Book')!;
        expect(favorites.find(saved.id, ComicType.local), ['Imports']);
        expect(
          File(
            '${manager.path}/${saved.directory}/${saved.cover}',
          ).existsSync(),
          isTrue,
        );
      },
    );
  }

  test(
    'PDF release failure preserves the rolled-back registration failure',
    () async {
      execute('local_favorite.db', '''
      CREATE TRIGGER reject_insert BEFORE INSERT ON "Imports"
      BEGIN SELECT RAISE(ABORT, 'original favorite failure'); END;
    ''');
      execute('local.db', '''
      CREATE TRIGGER reject_delete BEFORE DELETE ON comics
      BEGIN SELECT RAISE(ABORT, 'local compensation failure'); END;
    ''');
      final release = StateError('document release failure');
      final document = _Document(releaseError: release);
      await expectLater(
        PdfComicImporter.importDocument(
          document,
          title: 'Book',
          registerComic: (comic) =>
              service.registerComic(comic, folder: 'Imports'),
        ),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (error) => error.commitState,
                'state',
                PersistenceCommitState.notCommitted,
              )
              .having(
                (error) => error.cause.toString(),
                'cause',
                contains('original favorite failure'),
              )
              .having(
                (error) => error.cleanupFailures.last.error,
                'release',
                same(release),
              ),
        ),
      );
      expect(document.disposeCalls, 1);
      expect(manager.findByName('Book'), isNull);
      expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'queued coordinated registration captures input and allocates its ID at execution',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final delayed = _DelayedFavorites(favorites, entered, release.future);
      final injected = ComicImportService(
        localManager: () => manager,
        favoritesManager: () => delayed,
      );
      final tags = ['original'];
      final chapters = {'one': 'Original chapter'};
      final downloaded = ['one'];
      final comic = LocalComic(
        id: '0',
        title: 'Detached',
        subtitle: 'Author',
        tags: tags,
        directory: 'Detached',
        chapters: ComicChapters(chapters),
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: downloaded,
        createdAt: DateTime(2024),
      );
      final importing = injected.runImport(
        (operation) => operation.registerComics({
          'Imports': [comic],
        }, copy: false),
      );
      await entered.future;
      tags.add('late');
      chapters['two'] = 'Late chapter';
      downloaded.add('two');
      await manager.add(
        LocalComic(
          id: '1',
          title: 'Concurrent',
          subtitle: '',
          tags: [],
          directory: 'Concurrent',
          chapters: null,
          cover: '1.jpg',
          comicType: ComicType.local,
          downloadedChapters: [],
          createdAt: DateTime(2024),
        ),
      );
      var replacementStarted = false;
      final replacement = AppDataOperations.instance.run(() {
        replacementStarted = true;
        expect(manager.findByName('Detached'), isNotNull);
        expect(favorites.getFolderComics('Imports'), hasLength(1));
      });
      expect(replacementStarted, isFalse);
      release.complete();
      expect((await importing).importedCount, 1);
      await replacement;
      final saved = manager.findByName('Detached')!;
      expect(saved.id, '2');
      expect(saved.tags, ['original']);
      expect(saved.chapters!.ids, ['one']);
      expect(saved.downloadedChapters, ['one']);
      expect(favorites.getFolderComics('Imports').single.id, '2');
      expect(favorites.getFolderComics('Imports').single.tags, ['original']);
    },
  );

  test('PDF release failure after registration reports committed', () async {
    final release = StateError('document release failure');
    final document = _Document(releaseError: release);
    await expectLater(
      PdfComicImporter.importDocument(
        document,
        title: 'Book',
        registerComic: service.registerComic,
      ),
      throwsA(
        isA<PersistenceFailure>()
            .having(
              (error) => error.commitState,
              'state',
              PersistenceCommitState.committed,
            )
            .having((error) => error.cause, 'cause', same(release)),
      ),
    );
    expect(document.disposeCalls, 1);
    final saved = manager.findByName('Book')!;
    expect(
      File('${manager.path}/${saved.directory}/${saved.cover}').existsSync(),
      isTrue,
    );
  });

  test('PDF admission rejection preserves a failed release', () async {
    final releaseExit = await LocalComicStorageGuard.instance.prepareForExit();
    final error = StateError('document release failure');
    final document = _Document(releaseError: error);
    try {
      await expectLater(
        PdfComicImporter.importDocument(document, title: 'Book'),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (failure) => failure.commitState,
                'state',
                PersistenceCommitState.notCommitted,
              )
              .having(
                (failure) => failure.cause,
                'admission',
                isA<LocalComicStorageBusy>(),
              )
              .having(
                (failure) => failure.cleanupFailures.single.error,
                'release',
                same(error),
              ),
        ),
      );
      expect(document.disposeCalls, 1);
      expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
    } finally {
      releaseExit();
    }
  });

  test(
    'output cleanup retains the original failure and can retry deletion',
    () async {
      final source = Directory('${root.path}/owned')..createSync();
      File('${source.path}/page.jpg').writeAsStringSync('keep until release');
      final cleanup = StateError('delete failed');
      final directory = _FailedDelete(source, cleanup);
      final output = ComicImportOutput(directory);
      final original = StateError('conversion failed');
      final stack = StackTrace.current;
      await expectLater(
        output.fail(original, stack),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (error) => error.commitState,
                'state',
                PersistenceCommitState.notCommitted,
              )
              .having((error) => error.cause, 'cause', same(original))
              .having(
                (error) => error.cleanupFailures.single.error,
                'cleanup',
                same(cleanup),
              ),
        ),
      );
      expect(source.existsSync(), isTrue);
      directory.failDeletion = false;
      await expectLater(output.fail(original, stack), throwsA(same(original)));
      expect(source.existsSync(), isFalse);
    },
  );
  for (final mode in ['afterCommit', 'unreadable', 'rollbackError']) {
    test('local failed-add outcome remains unknown: $mode', () async {
      final original = StateError('local acknowledgement failed');
      final stack = StackTrace.current;
      final failure = mode == 'rollbackError'
          ? SqliteTransactionRollbackError(
              original,
              stack,
              StateError('rollback failed'),
              stack,
            )
          : original;
      final lookupError = mode == 'unreadable'
          ? StateError('verification failed')
          : null;
      final injected = ComicImportService(
        localManager: () =>
            _LocalAfterWrite(manager, failure, stack, lookupError: lookupError),
        favoritesManager: () => favorites,
      );
      await expectLater(
        import('cbz', injected.registerComic),
        throwsA(
          isA<PersistenceFailure>()
              .having(
                (error) => error.commitState,
                'state',
                PersistenceCommitState.unknown,
              )
              .having((error) => error.cause, 'cause', same(failure))
              .having(
                (error) => error.cleanupFailures.length,
                'verification failures',
                lookupError == null ? 0 : 1,
              ),
        ),
      );
      final saved = manager.findByName('Book')!;
      expect(
        File('${manager.path}/${saved.directory}/${saved.cover}').existsSync(),
        isTrue,
      );
    });
  }
}

class _LocalAfterWrite extends Fake implements LocalManager {
  _LocalAfterWrite(this.actual, this.error, this.stack, {this.lookupError});
  final LocalManager actual;
  final Object error;
  final StackTrace stack;
  final Object? lookupError;
  @override
  void requireStorageAccess() => actual.requireStorageAccess();
  @override
  String findValidId(ComicType type) => actual.findValidId(type);
  @override
  Future<void> add(LocalComic comic, [String? id]) async {
    await actual.add(comic, id);
    Error.throwWithStackTrace(error, stack);
  }

  @override
  LocalComic? find(String id, ComicType type) {
    if (lookupError != null) throw lookupError!;
    return actual.find(id, type);
  }
}

class _FavoritesAfterWrite extends Fake implements LocalFavoritesManager {
  _FavoritesAfterWrite(this.actual, this.error, this.stack);
  final LocalFavoritesManager actual;
  final Object error;
  final StackTrace stack;
  @override
  Future<void> addComicWithStorage(
    String folder,
    List<String> tags,
    FavoriteItem Function(
      String databasePath,
      String translatedTags,
      bool append,
    )
    commit,
  ) async {
    await actual.addComicWithStorage(folder, tags, commit);
    Error.throwWithStackTrace(error, stack);
  }
}

class _DelayedFavorites extends Fake implements LocalFavoritesManager {
  _DelayedFavorites(this.actual, this.entered, this.release);
  final LocalFavoritesManager actual;
  final Completer<void> entered;
  final Future<void> release;
  @override
  Future<void> addComicWithStorage(
    String folder,
    List<String> tags,
    FavoriteItem Function(
      String databasePath,
      String translatedTags,
      bool append,
    )
    commit,
  ) async {
    entered.complete();
    await release;
    await actual.addComicWithStorage(folder, tags, commit);
  }
}

class _FailedDelete extends Fake implements Directory {
  _FailedDelete(this.actual, this.error);
  final Directory actual;
  final Object error;
  bool failDeletion = true;
  @override
  String get path => actual.path;
  @override
  bool existsSync() => actual.existsSync();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (failDeletion) throw error;
    return actual.delete(recursive: recursive);
  }
}

class _Document extends Fake implements PdfDocument {
  _Document({this.releaseError});
  final Object? releaseError;
  int disposeCalls = 0;
  @override
  final pages = [_Page()];
  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (releaseError != null) throw releaseError!;
  }
}

class _Page extends Fake implements PdfPage {
  @override
  double get width => 2;
  @override
  double get height => 3;
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = 0,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async => _Image();
}

class _Image extends Fake implements PdfImage {
  @override
  int get width => 6;
  @override
  int get height => 9;
  @override
  final pixels = Uint8List(6 * 9 * 4)..fillRange(0, 6 * 9 * 4, 255);
  @override
  void dispose() {}
}
