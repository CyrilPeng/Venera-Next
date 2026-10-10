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

  void alias(String link, String target) {
    if (Platform.isWindows) {
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        link.replaceAll('/', '\\'),
        target.replaceAll('/', '\\'),
      ]);
      if (result.exitCode != 0) {
        throw StateError('Cannot create junction: ${result.stderr}');
      }
    } else {
      Link(link).createSync(target);
    }
  }

  test('deletion protects a registration through a filesystem alias', () async {
    final target = Directory('${manager.path}/target')..createSync();
    final page = File('${target.path}/1.jpg')..writeAsStringSync('keep');
    final link = '${manager.path}/alias';
    alias(link, target.path);
    final first = comic('target', 'target');
    await manager.add(first);
    await manager.add(comic('alias', link));
    await manager.deleteComic(first);
    expect(page.readAsStringSync(), 'keep');
    expect(manager.find('alias', first.comicType), isNotNull);
  });

  test('chapter deletion protects another retained chapter alias', () async {
    final target = Directory('${manager.path}/book/a')
      ..createSync(recursive: true);
    final page = File('${target.path}/1.jpg')..writeAsStringSync('keep');
    alias('${manager.path}/book/b', target.path);
    final book = comic('book', 'book', chapters: ['a', 'b']);
    await manager.add(book);
    await manager.deleteComicChapters(book, ['a']);
    expect(page.readAsStringSync(), 'keep');
    expect(manager.find('book', book.comicType)!.downloadedChapters, ['b']);
  });

  test('batch deletion protects an aliased descendant reference', () async {
    final target = Directory('${manager.path}/target/child')
      ..createSync(recursive: true);
    final page = File('${target.path}/1.jpg')..writeAsStringSync('keep');
    alias('${manager.path}/alias', '${manager.path}/target');
    final parent = comic('target', 'target');
    await manager.add(parent);
    await manager.add(comic('child', '${manager.path}/alias/child'));
    await manager.batchDeleteComics([parent], true, false);
    expect(page.readAsStringSync(), 'keep');
  });

  test('deletion never traverses an alias of the library root', () async {
    final link = '${root.path}/library-alias';
    alias(link, manager.path);
    final page = File('${manager.path}/keep.jpg')..writeAsStringSync('keep');
    final book = comic('library-alias', link);
    await manager.add(book);
    await manager.deleteComic(book);
    expect(page.readAsStringSync(), 'keep');
    expect(manager.directory.existsSync(), isTrue);
  });

  for (final operation in ['single', 'batch', 'chapter']) {
    test(
      '$operation preflight failure preserves records and supports retry',
      () async {
        final directory = Directory('${manager.path}/book/a')
          ..createSync(recursive: true);
        final page = File('${directory.path}/1.jpg')..writeAsStringSync('keep');
        final book = comic('book', 'book', chapters: ['a', 'b']);
        await manager.add(book);
        final target = Directory('${root.path}/missing-target')..createSync();
        final link = '${root.path}/broken';
        alias(link, target.path);
        target.deleteSync();
        final broken = comic('broken', link);
        await manager.add(broken);
        Future<void> removeBook() => switch (operation) {
          'single' => manager.deleteComic(book),
          'batch' => manager.batchDeleteComics([book], true, false),
          _ => manager.deleteComicChapters(book, ['a']),
        };
        var notifications = 0;
        manager.addListener(() => notifications++);
        await expectLater(removeBook(), throwsA(isA<FileSystemException>()));
        expect(manager.find(book.id, book.comicType)!.downloadedChapters, [
          'a',
          'b',
        ]);
        expect(page.readAsStringSync(), 'keep');
        expect(notifications, 0);
        // Unregistering a reference without disk cleanup remains available even
        // when its native identity is broken. Then retry the original operation.
        await manager.deleteComic(broken, false);
        await removeBook();
        expect(page.existsSync(), isFalse);
        if (operation == 'chapter') {
          expect(manager.find(book.id, book.comicType)!.downloadedChapters, [
            'b',
          ]);
        } else {
          expect(manager.find(book.id, book.comicType), isNull);
        }
      },
    );
  }

  for (final committed in [false, true]) {
    test(
      'manager startup recovers ${committed ? "committed" : "prepared"} deletion',
      () async {
        final original = Directory('${manager.path}/interrupted')..createSync();
        File('${original.path}/old').writeAsStringSync('original');
        final item = comic('interrupted', 'interrupted');
        await manager.add(item);
        final quarantine = '${manager.path}/.venera-delete-restart';
        final db = sqlite3.open('${root.path}/local.db');
        try {
          db.execute(
            'INSERT INTO local_deletion_journal(original_path,quarantine_path,committed) VALUES(?,?,?)',
            [original.path, quarantine, committed ? 1 : 0],
          );
          if (committed) {
            db.execute("DELETE FROM comics WHERE id = 'interrupted'");
          }
        } finally {
          db.dispose();
        }
        await original.rename(quarantine);
        if (committed) {
          original.createSync();
          File('${original.path}/new').writeAsStringSync('new owner');
        }
        await manager.pendingDownloadTaskWrites;
        LocalManager.current?.dispose();
        LocalManager(initializeSources: () async {});
        manager = LocalManager();
        await manager.init();
        expect(Directory(quarantine).existsSync(), isFalse);
        if (committed) {
          expect(manager.find(item.id, item.comicType), isNull);
          expect(File('${original.path}/new').readAsStringSync(), 'new owner');
        } else {
          expect(manager.find(item.id, item.comicType), isNotNull);
          expect(File('${original.path}/old').readAsStringSync(), 'original');
        }
      },
    );
  }
}
