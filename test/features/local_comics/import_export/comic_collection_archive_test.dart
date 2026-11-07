import 'dart:io';

import 'package:archive/archive_io.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/local_comics/import_export/comic_collection_archive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory workspace;
  late File source;

  setUp(() {
    root = Directory.systemTemp.createTempSync('comic-collection-');
    workspace = Directory(p.join(root.path, 'workspace'))..createSync();
    source = File(p.join(root.path, 'collection.zip'));
  });
  tearDown(() {
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
      isTrue,
    );
    root.deleteSync(recursive: true);
  });

  void writeZip(List<archive.ArchiveFile> entries) {
    final output = archive.OutputMemoryStream();
    final encoder = archive.ZipEncoder()..startEncode(output);
    for (final entry in entries) {
      encoder.add(entry);
    }
    encoder.endEncode();
    source.writeAsBytesSync(output.getBytes());
  }

  test(
    'extracts UTF-8 comic/chapter names and explicit empty directories',
    () async {
      writeZip([
        archive.ArchiveFile.directory('Book/'),
        archive.ArchiveFile.bytes('Book/1.png', [1, 2, 3]),
        archive.ArchiveFile.bytes('漫画/第一章/1.png', [4, 5, 6]),
        archive.ArchiveFile.directory('Empty/'),
      ]);
      await extractComicCollection(source, workspace);
      expect(File(p.join(workspace.path, 'Book', '1.png')).readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(
        File(p.join(workspace.path, '漫画', '第一章', '1.png')).readAsBytesSync(),
        [4, 5, 6],
      );
      expect(Directory(p.join(workspace.path, 'Empty')).existsSync(), isTrue);
      expect(source.existsSync(), isTrue);
    },
  );

  Future<ComicCollectionLayout> inspectPaths(List<String> names) async {
    writeZip([
      for (final name in names) archive.ArchiveFile.bytes(name, [1, 2, 3]),
    ]);
    await extractComicCollection(source, workspace);
    return inspectComicCollection(workspace);
  }

  test(
    'recognizes one outer folder when a contained comic has chapters',
    () async {
      final layout = await inspectPaths([
        'Collection/Book 10/1.png',
        'Collection/Book 2/Chapter/1.png',
      ]);
      expect(layout.root.path, p.join(workspace.path, 'Collection'));
      expect(layout.enclosingComic, isNull);
      expect(layout.comicTitles, ['Book 2', 'Book 10']);
      expect(source.existsSync(), isTrue);
    },
  );

  test('keeps normal multi-book roots unchanged', () async {
    final layout = await inspectPaths(['Book A/1.png', 'Book B/Chapter/1.png']);
    expect(layout.root.path, workspace.path);
    expect(layout.enclosingComic, isNull);
  });

  for (final names in [
    ['Collection/Book A/1.png', 'Collection/Book B/1.png'],
    ['Book/Chapter 1/1.png', 'Book/Chapter 2/1.png'],
    ['Collection/Book A/1.png'],
  ]) {
    test(
      'marks structurally ambiguous books/chapters for confirmation: $names',
      () async {
        final layout = await inspectPaths(names);
        expect(layout.enclosingComic, names.first.split('/').first);
        expect(
          layout.comicTitles,
          names.map((name) => name.split('/')[1]).toList(),
        );
        expect(layout.root.path, p.join(workspace.path, layout.enclosingComic));
      },
    );
  }

  for (final names in [
    ['Book/1.png', 'Book/2.png'],
    ['Book/cover.PNG', 'Book/Chapter 1/1.png', 'Book/Chapter 2/1.png'],
    ['Book/1.png', 'Book/Chapter/1.png'],
  ]) {
    test('pages or a cover keep a single comic root intact: $names', () async {
      final layout = await inspectPaths(names);
      expect(layout.root.path, workspace.path);
      expect(layout.enclosingComic, isNull);
    });
  }

  test('ignores ZIP sidecars for detection but keeps their bytes', () async {
    final layout = await inspectPaths([
      '.DS_Store',
      '._cover.png',
      '__MACOSX/._Book',
      'README.txt',
      'Collection/.hidden/1.png',
      'Collection/Book/Chapter/1.png',
    ]);
    expect(layout.root.path, p.join(workspace.path, 'Collection'));
    expect(layout.enclosingComic, isNull);
    expect(layout.comicTitles, ['Book']);
    expect(File(p.join(workspace.path, '.DS_Store')).readAsBytesSync(), [
      1,
      2,
      3,
    ]);
  });

  test(
    'does not flatten a malformed deep tree or multiple wrapper roots',
    () async {
      final layout = await inspectPaths([
        'Outer/Another/Book/Chapter/1.png',
        'Other/Book/1.png',
      ]);
      expect(layout.root.path, workspace.path);
      expect(layout.enclosingComic, isNull);
    },
  );

  test('rejects a wrapped unsafe path before writing good comics', () async {
    writeZip([
      archive.ArchiveFile.bytes('Collection/Good/1.png', [1]),
      archive.ArchiveFile.bytes('Collection/.hidden/../../escape.png', [2]),
    ]);
    await expectLater(
      extractComicCollection(source, workspace),
      throwsFormatException,
    );
    expect(workspace.listSync(), isEmpty);
  });

  for (final name in [
    '../escape.png',
    '/absolute.png',
    r'C:\escape.png',
    'Book/../escape.png',
    'Book/drive:stream.png',
    'Book/NUL.png',
    'Book/space /1.png',
    'Book/dot./1.png',
    '${List.filled(33, 'Deep').join('/')}/1.png',
  ]) {
    test('rejects unsafe path before writing any entries: $name', () async {
      writeZip([
        archive.ArchiveFile.bytes('Good/1.png', [1]),
        archive.ArchiveFile.bytes(name, [2]),
      ]);
      await expectLater(
        extractComicCollection(source, workspace),
        throwsFormatException,
      );
      expect(workspace.listSync(), isEmpty);
      expect(File(p.join(root.path, 'escape.png')).existsSync(), isFalse);
    });
  }

  for (final mode in [0xa1ff, 0x21a4, 0x11a4, 0xc1a4]) {
    test(
      'rejects links and special files before materializing them: $mode',
      () async {
        writeZip([
          archive.ArchiveFile.bytes('Good/1.png', [1]),
          archive.ArchiveFile.bytes('Book/special', '../elsewhere'.codeUnits)
            ..mode = mode,
        ]);
        await expectLater(
          extractComicCollection(source, workspace),
          throwsFormatException,
        );
        expect(workspace.listSync(), isEmpty);
      },
    );
  }

  for (final names in [
    ['Book/1.png', 'Book/1.png'],
    ['Book/1.png', './book/1.png'],
    ['Book', 'Book/1.png'],
    ['Book/1.png', 'Book'],
  ]) {
    test('rejects duplicate and file/parent collisions: $names', () async {
      writeZip([
        for (final name in names) archive.ArchiveFile.bytes(name, [1]),
      ]);
      await expectLater(
        extractComicCollection(source, workspace),
        throwsFormatException,
      );
      expect(workspace.listSync(), isEmpty);
    });
  }

  test('root images require the ordinary comic archive entry point', () async {
    writeZip([
      archive.ArchiveFile.bytes('1.PNG', [1]),
    ]);
    await expectLater(
      extractComicCollection(source, workspace),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('root must contain comic folders'),
        ),
      ),
    );
    expect(workspace.listSync(), isEmpty);
  });

  test('damaged stored data cannot pass the explicit CRC check', () async {
    writeZip([
      archive.ArchiveFile.noCompress('Book/1.png', 4, [71, 72, 73, 74]),
    ]);
    final bytes = source.readAsBytesSync();
    final nameLength = bytes[26] | bytes[27] << 8;
    final extraLength = bytes[28] | bytes[29] << 8;
    final data = 30 + nameLength + extraLength;
    expect(bytes.sublist(data, data + 4), [71, 72, 73, 74]);
    bytes[data] = 70;
    source.writeAsBytesSync(bytes);
    await expectLater(
      extractComicCollection(source, workspace),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('damaged file data'),
        ),
      ),
    );
  });

  test('a nonempty workspace is never overwritten', () async {
    final keep = File(p.join(workspace.path, 'keep'))
      ..writeAsStringSync('untouched');
    writeZip([
      archive.ArchiveFile.bytes('Book/1.png', [1]),
    ]);
    await expectLater(
      extractComicCollection(source, workspace),
      throwsStateError,
    );
    expect(keep.readAsStringSync(), 'untouched');
    expect(workspace.listSync(), hasLength(1));
  });
}
