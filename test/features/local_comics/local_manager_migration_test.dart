import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/local_comics/import_export/comic_import_service.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager manager;
  LocalComic comic(String id, String directory) => LocalComic(
    id: id,
    title: 'Book $id',
    subtitle: 'Author',
    tags: [],
    directory: directory,
    chapters: null,
    cover: '1.jpg',
    comicType: ComicType.local,
    downloadedChapters: [],
    createdAt: DateTime(2024),
  );
  Future<void> initialize() async {
    LocalManager(initializeSources: () async {});
    manager = LocalManager();
    await manager.init();
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('manager-relocation-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    LocalManager.current?.dispose();
    await initialize();
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.current?.dispose();
    root.deleteSync(recursive: true);
  });
  Directory book(String path, [String content = 'original page']) {
    final directory = Directory(path)..createSync(recursive: true);
    File(p.join(path, '1.jpg')).writeAsStringSync(content);
    return directory;
  }

  Future<void> readable(LocalComic model, String expected) async {
    expect(model.coverFile.readAsStringSync(), expected);
    final images = await manager.getImages(model.id, model.comicType, 1);
    expect(images, hasLength(1));
    expect(
      File(images.single.replaceFirst('file://', '')).readAsStringSync(),
      expected,
    );
  }

  for (final copied in [false, true]) {
    test(
      'actual ${copied ? 'copy import' : 'legacy relative import'} remains readable through round trips and reopening',
      () async {
        final originalRoot = manager.path;
        final source = book(p.join(copied ? root.path : manager.path, 'Book'));
        final input = comic('1', copied ? source.path : 'Book');
        if (copied) {
          final result =
              await ComicImportService(
                localManager: () => manager,
                favoritesManager: LocalFavoritesManager.new,
              ).runImport(
                (operation) => operation.registerComics({
                  null: [input],
                }, copy: true),
              );
          expect(result.importedCount, 1);
          expect(result.issues, isEmpty);
        } else {
          await manager.add(input);
        }
        final cached = <LocalComic>[
          manager.find('1', ComicType.local)!,
          manager.getRecent().single,
          manager.search('Book').single,
          manager.findByName('Book 1')!,
          manager.getComics(LocalSortType.name).single,
        ];
        final second = Directory(p.join(root.path, 'second'))..createSync();
        for (final target in [second.path, originalRoot, second.path]) {
          expect(await manager.setNewPath(target), isNull);
          cached.add(manager.find('1', ComicType.local)!);
          for (final model in cached) {
            expect(p.isWithin(target, model.baseDir), isTrue);
            await readable(model, 'original page');
          }
          if (!copied) expect(input.baseDir, p.join(target, 'Book'));
        }
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        await initialize();
        expect(manager.path, second.path);
        await readable(manager.find('1', ComicType.local)!, 'original page');
      },
    );
  }

  test(
    'removed models do not attach to a later registration reusing their ID and directory',
    () async {
      final original = book(p.join(manager.path, 'Book'));
      await manager.add(comic('1', original.path));
      final removed = manager.find('1', ComicType.local)!;
      manager.remove('1', ComicType.local);
      await manager.add(comic('1', original.path));
      final replacement = manager.find('1', ComicType.local)!;
      final destination = Directory(p.join(root.path, 'moved'))..createSync();
      expect(await manager.setNewPath(destination.path), isNull);
      expect(removed.baseDir, original.path);
      expect(replacement.baseDir, p.join(destination.path, 'Book'));
      await readable(replacement, 'original page');
    },
  );

  test(
    'models from a disposed manager retain that library after a new store moves',
    () async {
      book(p.join(manager.path, 'Book'), 'old store');
      await manager.add(comic('1', 'Book'));
      final previous = manager.find('1', ComicType.local)!;
      final previousPath = previous.baseDir;
      await manager.pendingDownloadTaskWrites;
      LocalManager.current?.dispose();
      final nextData = Directory(p.join(root.path, 'next-data'))..createSync();
      App.dataPath = nextData.path;
      App.cachePath = nextData.path;
      await initialize();
      book(p.join(manager.path, 'Book'), 'new store');
      await manager.add(comic('1', 'Book'));
      final current = manager.find('1', ComicType.local)!;
      final destination = Directory(p.join(root.path, 'moved'))..createSync();
      expect(await manager.setNewPath(destination.path), isNull);
      expect(previous.baseDir, previousPath);
      expect(previous.coverFile.readAsStringSync(), 'old store');
      await readable(current, 'new store');
    },
  );

  void alias(String link, String target) {
    if (Platform.isWindows) {
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        link,
        target,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Cannot create junction: ${result.stderr}');
      }
    } else {
      Link(link).createSync(target);
    }
  }

  test(
    'library rooted at a native alias relocates its physical references',
    () async {
      final physical = book(p.join(manager.path, 'Book'));
      final libraryAlias = p.join(root.path, 'library-alias');
      alias(libraryAlias, manager.path);
      manager.path = libraryAlias;
      File(p.join(root.path, 'local_path')).writeAsStringSync(libraryAlias);
      await manager.add(comic('1', physical.path));
      final cached = manager.find('1', ComicType.local)!;
      final destination = Directory(p.join(root.path, 'moved'))..createSync();
      expect(await manager.setNewPath(destination.path), isNull);
      expect(cached.baseDir, p.join(destination.path, 'Book'));
      await readable(cached, 'original page');
      expect(physical.existsSync(), isFalse);
    },
  );

  test(
    'external alias into the library moves while a genuine external book stays literal',
    () async {
      final internal = book(p.join(manager.path, 'Book'));
      final link = p.join(root.path, 'alias');
      alias(link, internal.path);
      final external = book('${manager.path}-external', 'external page');
      await manager.add(comic('1', link));
      await manager.add(comic('2', external.path));
      final internalModel = manager.find('1', ComicType.local)!;
      final externalModel = manager.find('2', ComicType.local)!;
      final destination = Directory(p.join(root.path, 'moved'))..createSync();
      expect(await manager.setNewPath(destination.path), isNull);
      expect(internalModel.baseDir, p.join(destination.path, 'Book'));
      expect(externalModel.baseDir, external.path);
      await readable(internalModel, 'original page');
      await readable(externalModel, 'external page');
    },
  );

  test(
    'committed missing destination stops startup instead of choosing an empty default',
    () async {
      book(p.join(manager.path, 'Book'));
      await manager.add(comic('1', p.join(manager.path, 'Book')));
      final destination = Directory(p.join(root.path, 'moved'))..createSync();
      // The directory blocks the atomic path-file rename after SQLite commits.
      Directory(p.join(root.path, 'local_path')).createSync();
      expect(await manager.setNewPath(destination.path), isNotNull);
      expect(manager.path, destination.path);
      destination.deleteSync(recursive: true);
      await manager.pendingDownloadTaskWrites;
      LocalManager.current?.dispose();
      LocalManager(initializeSources: () async {});
      manager = LocalManager();
      await expectLater(manager.init(), throwsA(isA<FileSystemException>()));
      expect(destination.existsSync(), isFalse);
      final db = sqlite3.open(p.join(root.path, 'local.db'));
      try {
        expect(
          db
              .select('SELECT committed FROM local_storage_relocation')
              .single['committed'],
          1,
        );
        expect(
          db.select('SELECT directory FROM comics').single['directory'],
          p.join(destination.path, 'Book'),
        );
      } finally {
        db.dispose();
      }
    },
  );
}
