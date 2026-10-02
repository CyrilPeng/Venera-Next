import 'dart:convert';
import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/cbz.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
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
