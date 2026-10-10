import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  const service = ComicImportService(
    localManager: LocalManager.new,
    favoritesManager: _favoritesForView,
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  group('PDF import rendering', () {
    test('uses three times the PDF point size below the edge limit', () {
      final size = calculatePdfRenderSize(612, 792);

      expect(size.width, 1836);
      expect(size.height, 2376);
    });

    test('caps the longest edge while preserving the aspect ratio', () {
      final size = calculatePdfRenderSize(2000, 1000);

      expect(size.width, 3000);
      expect(size.height, 1500);
    });

    test('rejects invalid page dimensions', () {
      expect(
        () => calculatePdfRenderSize(0, 100),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group(
    'PDF import lifecycle',
    () {
      late Directory dataDirectory;
      late Directory cacheDirectory;
      late LocalManager manager;

      setUp(() async {
        dataDirectory = Directory.systemTemp.createTempSync('venera-pdf-data-');
        cacheDirectory = Directory.systemTemp.createTempSync(
          'venera-pdf-cache-',
        );
        App.dataPath = dataDirectory.path;
        App.cachePath = cacheDirectory.path;
        LocalManager.current?.dispose();
        LocalManager(initializeSources: () async {});
        manager = LocalManager();
        await manager.init();
      });

      tearDown(() {
        LocalManager.current?.dispose();
        dataDirectory.deleteSync(recursive: true);
        cacheDirectory.deleteSync(recursive: true);
      });

      Future<void> withFavorites(
        Future<void> Function(LocalFavoritesManager favorites) run,
      ) async {
        final followFolder = appdata.settings['followUpdatesFolder'];
        final quickFavorite = appdata.settings['quickFavorite'];
        _favoritesOwner = null;
        final favorites = _favoritesForView();
        try {
          await favorites.init();
          await run(favorites);
        } finally {
          await favorites.debugWaitForHashedIdsRefresh();
          await appdata.saveData(false);
          favorites.close();
          _favoritesOwner = null;
          appdata.settings['followUpdatesFolder'] = followFolder;
          appdata.settings['quickFavorite'] = quickFavorite;
        }
      }

      test(
        'storage migration cannot copy or delete a PDF still being imported',
        () async {
          final firstPageReady = Completer<void>();
          final renderGate = Completer<void>();
          final originalPath = manager.path;
          final destination = Directory(
            FilePath.join(dataDirectory.path, 'migrated'),
          )..createSync();
          final importing = PdfComicImporter.importDocument(
            _Document([_Page(), _Page(waitBeforeRender: renderGate.future)]),
            title: 'In progress',
            onProgress: (current, total) {
              if (current == 1) firstPageReady.complete();
            },
            registerComic: (comic) => service.registerComic(comic),
          );
          // Always finish the renderer, including when a regression assertion
          // fails, so test cleanup cannot race a live import.
          addTearDown(() async {
            if (!renderGate.isCompleted) renderGate.complete();
            try {
              await importing;
            } catch (_) {}
          });
          await firstPageReady.future;
          expect(await manager.setNewPath(destination.path), isNotNull);
          expect(manager.path, originalPath);
          expect(destination.listSync(), isEmpty);
          renderGate.complete();
          await importing;
          expect(
            await manager.getImages('1', ComicType.local, 1),
            hasLength(2),
          );
          expect(await manager.setNewPath(destination.path), isNull);
          expect(
            await manager.getImages('1', ComicType.local, 1),
            hasLength(2),
          );
        },
      );

      test('failed PDF import releases storage for migration', () async {
        final destination = Directory(
          FilePath.join(dataDirectory.path, 'after-failure'),
        )..createSync();
        await expectLater(
          PdfComicImporter.importDocument(
            _Document([_Page(returnsNull: true)]),
            title: 'Broken',
          ),
          throwsA(isA<PdfPageRenderException>()),
        );
        expect(await manager.setNewPath(destination.path), isNull);
        expect(destination.listSync(), isEmpty);
      });

      testWidgets(
        'library recovery refuses to register a partially converted PDF',
        (tester) async {
          await tester.pumpWidget(
            _libraryView(
              MaterialApp(
                navigatorKey: appNavigation.rootNavigatorKey,
                home: const Scaffold(),
              ),
            ),
          );
          await tester.runAsync(() async {
            final firstPageReady = Completer<void>();
            final renderGate = Completer<void>();
            final importing = PdfComicImporter.importDocument(
              _Document([_Page(), _Page(waitBeforeRender: renderGate.future)]),
              title: 'Still importing',
              onProgress: (current, total) {
                if (current == 1) firstPageReady.complete();
              },
              registerComic: (comic) => service.registerComic(comic),
            );
            try {
              await firstPageReady.future;
              expect(await const ImportComic().localDownloads(), isFalse);
              expect(manager.count, 0);
            } finally {
              renderGate.complete();
              await importing;
            }
            expect(manager.count, 1);
            expect(
              await manager.getImages('1', ComicType.local, 1),
              hasLength(2),
            );
          });
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );

      test(
        'registers multiple comics in the selected favorites folder',
        () async {
          await withFavorites((favorites) async {
            final folder = await favorites.createFolder('PDFs');
            for (var index = 1; index <= 2; index++) {
              await PdfComicImporter.importDocument(
                _Document([_Page()]),
                title: 'Volume $index',
                registerComic: (comic) =>
                    service.registerComic(comic, folder: folder),
              );
            }
            expect(favorites.find('1', ComicType.local), contains(folder));
            expect(favorites.find('2', ComicType.local), contains(folder));
            expect(manager.find('1', ComicType.local)?.title, 'Volume 1');
            expect(manager.find('2', ComicType.local)?.title, 'Volume 2');
          });
        },
      );

      test(
        'favorite insertion failure rolls back the local record and converted pages',
        () async {
          await withFavorites((favorites) async {
            final folder = await favorites.createFolder('PDFs');
            final database = sqlite3.open(
              FilePath.join(App.dataPath, 'local_favorite.db'),
            );
            try {
              database.execute('''
            CREATE TRIGGER reject_pdf_favorite BEFORE INSERT ON "PDFs"
            BEGIN SELECT RAISE(ABORT, 'test insertion failure'); END;
          ''');
            } finally {
              database.dispose();
            }
            await expectLater(
              PdfComicImporter.importDocument(
                _Document([_Page()]),
                title: 'Unregistered',
                registerComic: (comic) =>
                    service.registerComic(comic, folder: folder),
              ),
              throwsA(
                isA<PersistenceFailure>()
                    .having(
                      (failure) => failure.commitState,
                      "state",
                      PersistenceCommitState.notCommitted,
                    )
                    .having(
                      (failure) => failure.cause,
                      "cause",
                      isA<SqliteException>(),
                    ),
              ),
            );
            expect(manager.findByName('Unregistered'), isNull);
            expect(favorites.find('1', ComicType.local), isEmpty);
            expect(
              manager.directory.listSync().whereType<Directory>(),
              isEmpty,
            );
          });
        },
      );

      test(
        'writes all pages and a cover before registering each comic with a unique ID',
        () async {
          final progress = <(int, int)>[];
          final document = _Document([_Page(), _Page()]);
          final comic = await PdfComicImporter.importDocument(
            document,
            title: 'Volume 1',
            onProgress: (current, total) => progress.add((current, total)),
            registerComic: (comic) => service.registerComic(comic),
          );
          final second = await PdfComicImporter.importDocument(
            _Document([_Page()]),
            title: 'Volume 2',
            registerComic: (comic) => service.registerComic(comic),
          );

          expect(progress, [(0, 2), (1, 2), (2, 2)]);
          expect(manager.find('1', ComicType.local)?.title, 'Volume 1');
          expect(manager.find('2', ComicType.local)?.title, 'Volume 2');
          expect(comic.id, isNot(second.id));
          final images = await manager.getImages('1', ComicType.local, 1);
          expect(images, hasLength(2));
          final bytes = File(
            FilePath.join(comic.baseDir, '0001.jpg'),
          ).readAsBytesSync();
          expect(image.decodeJpg(bytes), isNotNull);
          expect(comic.coverFile.readAsBytesSync(), bytes);
          expect(document.disposed, isTrue);
          expect(
            document.pages.every(
              (page) => page.renderedImage?.disposed == true,
            ),
            isTrue,
          );
        },
      );

      test(
        'cancellation before conversion closes the document without creating output',
        () async {
          final document = _Document([_Page()]);
          await expectLater(
            PdfComicImporter.importDocument(
              document,
              title: 'Cancelled',
              cancellation: DocumentImportCancellation()..cancel(),
            ),
            throwsA(isA<DocumentImportCancelled>()),
          );
          expect(document.disposed, isTrue);
          expect(document.pages.single.renderCount, 0);
          expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        },
      );

      test(
        'cancelling between pages removes only the unfinished comic',
        () async {
          final kept = await PdfComicImporter.importDocument(
            _Document([_Page()]),
            title: 'Kept',
            registerComic: (comic) => service.registerComic(comic),
          );
          final cancellation = DocumentImportCancellation();
          final document = _Document([_Page(), _Page()]);
          await expectLater(
            PdfComicImporter.importDocument(
              document,
              title: 'Cancelled',
              cancellation: cancellation,
              onProgress: (current, total) {
                if (current == 1) cancellation.cancel();
              },
              registerComic: (_) async =>
                  fail('Cancelled comic must not be registered'),
            ),
            throwsA(isA<DocumentImportCancelled>()),
          );

          expect(document.pages.first.renderCount, 1);
          expect(document.pages.last.renderCount, 0);
          expect(document.pages.first.renderedImage!.disposed, isTrue);
          expect(document.disposed, isTrue);
          expect(
            manager.directory.listSync().whereType<Directory>().map(
              (dir) => dir.name,
            ),
            [kept.directory],
          );
          expect(manager.findByName('Kept'), isNotNull);
          expect(manager.findByName('Cancelled'), isNull);
        },
      );

      test(
        'cancelling during rendering releases the returned native image',
        () async {
          final cancellation = DocumentImportCancellation();
          final page = _Page(onRender: cancellation.cancel);
          final document = _Document([page]);
          await expectLater(
            PdfComicImporter.importDocument(
              document,
              title: 'Cancelled',
              cancellation: cancellation,
            ),
            throwsA(isA<DocumentImportCancelled>()),
          );

          expect(page.renderedImage!.disposed, isTrue);
          expect(document.disposed, isTrue);
          expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        },
      );

      test(
        'cancelling after the last page prevents registration and removes output',
        () async {
          final cancellation = DocumentImportCancellation();
          final document = _Document([_Page()]);
          await expectLater(
            PdfComicImporter.importDocument(
              document,
              title: 'Cancelled',
              cancellation: cancellation,
              onProgress: (current, total) {
                if (current == total) cancellation.cancel();
              },
              registerComic: (_) async =>
                  fail('Cancelled comic must not be registered'),
            ),
            throwsA(isA<DocumentImportCancelled>()),
          );

          expect(document.disposed, isTrue);
          expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        },
      );

      test(
        'rendering failure removes partial output and releases resources',
        () async {
          final document = _Document([_Page(), _Page(returnsNull: true)]);
          await expectLater(
            PdfComicImporter.importDocument(document, title: 'Broken'),
            throwsA(
              isA<PdfPageRenderException>().having(
                (error) => error.page,
                'page',
                2,
              ),
            ),
          );

          expect(document.pages.first.renderedImage!.disposed, isTrue);
          expect(document.disposed, isTrue);
          expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
        },
      );

      test('failed registration cleans the uncommitted output', () async {
        final document = _Document([_Page()]);
        await expectLater(
          PdfComicImporter.importDocument(
            document,
            title: 'Unregistered',
            registerComic: (_) async => throw PersistenceFailure(
              commitState: PersistenceCommitState.notCommitted,
              cause: StateError('Registration failed'),
              stackTrace: StackTrace.current,
            ),
          ),
          throwsA(
            isA<PersistenceFailure>()
                .having((failure) => failure.cause, 'cause', isA<StateError>())
                .having(
                  (failure) => failure.commitState,
                  'state',
                  PersistenceCommitState.notCommitted,
                ),
          ),
        );
        expect(document.disposed, isTrue);
        expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
      });

      test(
        'exit rejection closes a document before conversion begins',
        () async {
          final release = await LocalComicStorageGuard.instance
              .prepareForExit();
          final document = _Document([_Page()]);
          try {
            await expectLater(
              PdfComicImporter.importDocument(document, title: 'Rejected'),
              throwsA(isA<LocalComicStorageBusy>()),
            );
            expect(document.disposed, isTrue);
            expect(
              manager.directory.listSync().whereType<Directory>(),
              isEmpty,
            );
          } finally {
            release();
          }
        },
      );

      test('empty documents are rejected and disposed', () async {
        final document = _Document([]);
        await expectLater(
          PdfComicImporter.importDocument(document, title: 'Empty'),
          throwsFormatException,
        );
        expect(document.disposed, isTrue);
        expect(manager.directory.listSync().whereType<Directory>(), isEmpty);
      });
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _Document extends Fake implements PdfDocument {
  _Document(this.pages);

  @override
  final List<_Page> pages;

  bool disposed = false;

  @override
  Future<void> dispose() async => disposed = true;
}

class _Page extends Fake implements PdfPage {
  _Page({this.onRender, this.returnsNull = false, this.waitBeforeRender});

  final void Function()? onRender;
  final Future<void>? waitBeforeRender;
  final bool returnsNull;
  int renderCount = 0;
  _Image? renderedImage;

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
  }) async {
    renderCount++;
    await waitBeforeRender;
    onRender?.call();
    if (returnsNull) return null;
    return renderedImage = _Image();
  }
}

class _Image extends Fake implements PdfImage {
  bool disposed = false;

  @override
  int get width => 6;

  @override
  int get height => 9;

  @override
  final Uint8List pixels = Uint8List(6 * 9 * 4)..fillRange(0, 6 * 9 * 4, 255);

  @override
  void dispose() => disposed = true;
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
Widget _libraryView(Widget child) {
  return FavoritesScope(manager: _favoritesForView(), child: child);
}
