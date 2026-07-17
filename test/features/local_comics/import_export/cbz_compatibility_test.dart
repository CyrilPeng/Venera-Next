import 'package:archive/archive_io.dart' as archive_io;
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  group('CBZ compatibility helpers', () {
    test(
      'compatiblePageFileName pads to four digits and preserves extension',
      () {
        expect(CBZ.compatiblePageFileName(1, 'jpg'), '0001.jpg');
      },
    );

    test(
      'buildComicInfoXmlForTesting includes page metadata without cover',
      () {
        final xml = CBZ.buildComicInfoXmlForTesting(
          ComicMetaData(
            title: 'Title & <Story>',
            author: 'Author "A" & Co',
            tags: ['tag <one>', 'tag & two'],
          ),
          pageCount: 3,
        );

        expect(xml, contains('<Title>Title &amp; &lt;Story&gt;</Title>'));
        expect(xml, contains('<Writer>Author &quot;A&quot; &amp; Co</Writer>'));
        expect(xml, contains('<Tags>tag &lt;one&gt;, tag &amp; two</Tags>'));
        expect(xml, isNot(contains('<Genre>')));
        expect(xml, contains('<PageCount>3</PageCount>'));
        expect(xml, contains('<Manga>Unknown</Manga>'));
        expect(xml, contains('<BlackAndWhite>Unknown</BlackAndWhite>'));
        expect(xml, contains('<Page Image="0" Type="Story" />'));
        expect(xml, contains('<Page Image="1" Type="Story" />'));
        expect(xml, contains('<Page Image="2" Type="Story" />'));
        expect(xml, isNot(contains('Type="FrontCover"')));
      },
    );

    test('buildChapterRangesForTesting calculates contiguous page ranges', () {
      final chapters = CBZ.buildChapterRangesForTesting({
        'Chapter 1': 2,
        'Chapter 2': 3,
      });

      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[0].start, 1);
      expect(chapters[0].end, 2);
      expect(chapters[1].title, 'Chapter 2');
      expect(chapters[1].start, 3);
      expect(chapters[1].end, 5);
    });

    test('localFilePathFromImageUriForTesting strips file URI prefix', () {
      final result = CBZ.localFilePathFromImageUriForTesting(
        'file:///tmp/a.jpg',
      );

      expect(result.startsWith('file://'), isFalse);
      expect(result, contains('a.jpg'));
    });

    test(
      'localFilePathFromImageUriForTesting leaves plain paths unchanged',
      () {
        const plainPath = '/tmp/a.jpg';

        expect(CBZ.localFilePathFromImageUriForTesting(plainPath), plainPath);
      },
    );

    test(
      'inspectImportLayoutForTesting detects chapter folders under a root folder',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          final root = Directory(FilePath.join(temp.path, '猫之眼[北条司]'))
            ..createSync();
          File(FilePath.join(root.path, 'cover.jpg')).writeAsBytesSync([1]);
          final chapter1 = Directory(FilePath.join(root.path, '第01卷'))
            ..createSync();
          final chapter2 = Directory(FilePath.join(root.path, '第02卷'))
            ..createSync();
          File(FilePath.join(chapter1.path, '002.jpg')).writeAsBytesSync([1]);
          File(FilePath.join(chapter1.path, '001.jpg')).writeAsBytesSync([1]);
          File(FilePath.join(chapter2.path, '001.jpg')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);
          final chapters = layout['chapters'] as Map<String, List<String>>;

          expect(layout['root'], '猫之眼[北条司]');
          expect(layout['cover'], 'cover.jpg');
          expect(layout['useChapterDirectories'], isTrue);
          expect(chapters.keys.toList(), ['第01卷', '第02卷']);
          expect(chapters['第01卷'], ['001.jpg', '002.jpg']);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'inspectImportLayoutForTesting uses first chapter image as cover when needed',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          final root = Directory(FilePath.join(temp.path, 'Book'))
            ..createSync();
          final chapter = Directory(FilePath.join(root.path, 'Chapter 1'))
            ..createSync();
          File(FilePath.join(chapter.path, '001.png')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);

          expect(layout['cover'], '001.png');
          expect(layout['useChapterDirectories'], isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'inspectImportLayoutForTesting keeps flat layout when root has pages',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          File(FilePath.join(temp.path, '001.jpg')).writeAsBytesSync([1]);
          final chapter = Directory(FilePath.join(temp.path, 'Chapter 1'))
            ..createSync();
          File(FilePath.join(chapter.path, '001.jpg')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);

          expect(layout['rootImages'], ['001.jpg']);
          expect(layout['useChapterDirectories'], isFalse);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'extractArchiveForTesting retries zip extraction with 7z fallback',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_extract_');
        try {
          final archive = File(FilePath.join(temp.path, 'legacy.cbz'))
            ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04]);
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();
          final calls = <String>[];

          await CBZ.extractArchiveForTesting(
            archive,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              calls.add('zip');
              File(
                FilePath.join(outputPath, 'partial.jpg'),
              ).writeAsBytesSync([1]);
              throw const FormatException('Missing extension byte', null, 24);
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              calls.add('7z');
              expect(
                File(FilePath.join(outputPath, 'partial.jpg')).existsSync(),
                isFalse,
              );
              File(FilePath.join(outputPath, '001.jpg')).writeAsBytesSync([1]);
            },
          );

          expect(calls, ['zip', '7z']);
          expect(File(FilePath.join(out.path, '001.jpg')).existsSync(), isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'extractArchiveForTesting retries Dart zip extraction when native extractors fail',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_extract_');
        try {
          final archive = File(FilePath.join(temp.path, 'legacy.cbz'))
            ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04]);
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();
          final calls = <String>[];

          await CBZ.extractArchiveForTesting(
            archive,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              calls.add('zip');
              throw const FormatException('Missing extension byte', null, 24);
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              calls.add('7z');
              throw Exception('Failed to open archive.');
            },
            dartZipExtractor: (archivePath, outputPath) async {
              calls.add('dart');
              File(FilePath.join(outputPath, '001.jpg')).writeAsBytesSync([1]);
            },
          );

          expect(calls, ['zip', '7z', 'dart']);
          expect(File(FilePath.join(out.path, '001.jpg')).existsSync(), isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test('extractArchiveForTesting extracts zip with Dart fallback', () async {
      final temp = Directory.systemTemp.createTempSync('cbz_extract_');
      try {
        final archive = archive_io.Archive()
          ..addFile(archive_io.ArchiveFile.directory('猫之眼[北条司]/'))
          ..addFile(archive_io.ArchiveFile.bytes('猫之眼[北条司]/第01卷/001.jpg', [1]));
        final archiveFile = File(FilePath.join(temp.path, 'book.cbz'))
          ..writeAsBytesSync(archive_io.ZipEncoder().encodeBytes(archive));
        final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

        await CBZ.extractArchiveForTesting(
          archiveFile,
          out,
          zipExtractor: (archivePath, outputPath, threads) async {
            throw const FormatException('Missing extension byte', null, 24);
          },
          sevenZipExtractor: (archivePath, outputPath, threads) async {
            throw Exception('Failed to open archive.');
          },
        );

        expect(
          File(
            FilePath.join(out.path, '猫之眼[北条司]', '第01卷', '001.jpg'),
          ).existsSync(),
          isTrue,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('extractArchiveForTesting decodes GBK zip entry names', () async {
      final temp = Directory.systemTemp.createTempSync('cbz_extract_');
      try {
        final archive = archive_io.Archive()
          ..addFile(archive_io.ArchiveFile.directory('猫之眼[北条司]/'))
          ..addFile(archive_io.ArchiveFile.bytes('猫之眼[北条司]/第01卷/001.jpg', [1]));
        final archiveFile = File(FilePath.join(temp.path, 'book.cbz'))
          ..writeAsBytesSync(
            archive_io.ZipEncoder(
              filenameEncoding: const GbkCodec(),
            ).encodeBytes(archive),
          );
        final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

        await CBZ.extractArchiveForTesting(
          archiveFile,
          out,
          zipExtractor: (archivePath, outputPath, threads) async {
            throw const FormatException('Missing extension byte', null, 24);
          },
          sevenZipExtractor: (archivePath, outputPath, threads) async {
            throw Exception('Failed to open archive.');
          },
        );

        expect(
          File(
            FilePath.join(out.path, '猫之眼[北条司]', '第01卷', '001.jpg'),
          ).existsSync(),
          isTrue,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
}
