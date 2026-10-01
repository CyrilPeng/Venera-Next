import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory root;
  late LocalManager manager;
  LocalComic comic(
    String id,
    String directory, {
    List<String> chapters = const [],
  }) => LocalComic(
    id: id,
    title: id,
    subtitle: '',
    tags: [],
    directory: directory,
    chapters: null,
    cover: 'cover.jpg',
    comicType: const ComicType(9001),
    downloadedChapters: chapters,
    createdAt: DateTime(2024),
  );
  setUp(() async {
    root = Directory.systemTemp.createTempSync('shared-local-');
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

  test(
    'unrelated malformed metadata does not break shared directory protection',
    () async {
      final directory = Directory('${manager.path}/shared')..createSync();
      final page = File('${directory.path}/1.jpg')..writeAsStringSync('keep');
      final first = comic('first', 'shared');
      await manager.add(first);
      await manager.add(comic('second', 'shared'));
      final db = sqlite3.open('${root.path}/local.db');
      try {
        db.execute(
          "UPDATE comics SET tags = 'invalid json' WHERE id = 'second'",
        );
        await manager.deleteComic(first);
        expect(page.readAsStringSync(), 'keep');
        expect(manager.count, 1);
        expect(db.select('SELECT id FROM comics').single['id'], 'second');
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'single deletion preserves shared output until the last registration is removed',
    () async {
      final directory = Directory('${manager.path}/shared')..createSync();
      final page = File('${directory.path}/1.jpg')..writeAsStringSync('shared');
      final first = comic('first', 'shared');
      final second = comic('second', '${directory.path}/.');
      await manager.add(first);
      await manager.add(second);
      await manager.deleteComic(first);
      expect(page.readAsStringSync(), 'shared');
      expect(manager.find(second.id, second.comicType), isNotNull);
      await manager.batchDeleteComics([second], true, false);
      expect(directory.existsSync(), isFalse);
    },
  );

  test(
    'chapter deletion protects another record rooted in that chapter',
    () async {
      final directory = Directory('${manager.path}/parent/a')
        ..createSync(recursive: true);
      final page = File('${directory.path}/1.jpg')
        ..writeAsStringSync('shared chapter');
      final parent = comic('parent', 'parent', chapters: ['a', 'b']);
      final child = comic('child', directory.path);
      await manager.add(parent);
      await manager.add(child);
      await manager.deleteComicChapters(parent, ['a']);
      expect(manager.find(parent.id, parent.comicType)!.downloadedChapters, [
        'b',
      ]);
      expect(page.readAsStringSync(), 'shared chapter');
      await manager.batchDeleteComics([child], false, false);
      await manager.deleteComicChapters(parent, ['a']);
      expect(directory.existsSync(), isFalse);
    },
  );

  test(
    'batch deletion retains a referenced descendant and never deletes the library root',
    () async {
      final directory = Directory('${manager.path}/parent/child')
        ..createSync(recursive: true);
      final page = File('${directory.path}/1.jpg')..writeAsStringSync('keep');
      final parent = comic('parent', 'parent');
      final child = comic('child', directory.path);
      final library = comic('library', manager.path);
      for (final entry in [parent, child, library]) {
        await manager.add(entry);
      }
      await manager.batchDeleteComics([parent, library], true, false);
      expect(page.readAsStringSync(), 'keep');
      expect(manager.directory.existsSync(), isTrue);
      expect(manager.count, 1);
    },
  );
}
