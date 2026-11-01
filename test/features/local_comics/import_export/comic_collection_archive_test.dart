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
