import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/foundation/file_system.dart';

void main() {
  group('comic file rules', () {
    test('recognizes images, archives, covers, and ignored entries', () {
      expect(isComicImageFileName('PAGE.JPEG'), isTrue);
      expect(isComicImageFileName('metadata.json'), isFalse);
      expect(isComicArchiveFileName('book.CBZ'), isTrue);
      expect(isNamedComicCover('COVER.WebP'), isTrue);
      expect(isNamedComicCover('cover_front.jpg'), isFalse);
      expect(isIgnoredComicStorageEntry('.hidden.jpg'), isTrue);
      expect(isIgnoredComicStorageEntry('__MACOSX'), isTrue);
    });

    test('sorts numeric names deterministically before lexical fallback', () {
      final names = ['10.jpg', '2.jpg', '01.jpg', '1.jpg', 'page.jpg'];

      names.sort(compareComicFileNames);

      expect(names, ['01.jpg', '1.jpg', '2.jpg', '10.jpg', 'page.jpg']);
    });

    test('filters non-images and optionally excludes named covers', () {
      final entries = ['2.jpg', 'metadata.json', 'cover.png', '1.JPG'];

      final pages = sortedComicImageEntries(
        entries,
        nameOf: (entry) => entry,
        includeCover: false,
      );

      expect(pages, ['1.JPG', '2.jpg']);
    });
  });

  group('comic file system layout', () {
    test('uses root pages for a mixed flat and chapter layout', () {
      final temp = Directory.systemTemp.createTempSync('comic_layout_');
      try {
        File(FilePath.join(temp.path, 'cover.JPG')).writeAsBytesSync([1]);
        File(FilePath.join(temp.path, '10.jpg')).writeAsBytesSync([1]);
        File(FilePath.join(temp.path, '2.jpg')).writeAsBytesSync([1]);
        File(FilePath.join(temp.path, 'metadata.json')).writeAsStringSync('{}');
        final chapter = Directory(FilePath.join(temp.path, 'Chapter 1'))
          ..createSync();
        File(FilePath.join(chapter.path, '1.jpg')).writeAsBytesSync([1]);

        final layout = ComicFileSystemLayout.inspect(temp);

        expect(layout.useChapterDirectories, isFalse);
        expect(layout.rootPages.map((file) => file.name), ['2.jpg', '10.jpg']);
        expect(layout.cover?.name, 'cover.JPG');
        expect(layout.inferredCover?.name, 'cover.JPG');
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('supports chapter directories without a root cover', () {
      final temp = Directory.systemTemp.createTempSync('comic_layout_');
      try {
        final chapter10 = Directory(FilePath.join(temp.path, '10'))
          ..createSync();
        final chapter2 = Directory(FilePath.join(temp.path, '2'))..createSync();
        File(FilePath.join(chapter2.path, 'cover.png')).writeAsBytesSync([1]);
        File(FilePath.join(chapter2.path, '2.JPG')).writeAsBytesSync([1]);
        File(FilePath.join(chapter2.path, '1.jpg')).writeAsBytesSync([1]);
        File(FilePath.join(chapter10.path, '1.jpg')).writeAsBytesSync([1]);

        final layout = ComicFileSystemLayout.inspect(temp);

        expect(layout.useChapterDirectories, isTrue);
        expect(layout.chapters.map((chapter) => chapter.title), ['2', '10']);
        expect(layout.chapters.first.pages.map((file) => file.name), [
          '1.jpg',
          '2.JPG',
        ]);
        expect(layout.inferredCover?.name, 'cover.png');
        expect(
          layout.relativePath(layout.inferredCover!),
          FilePath.join('2', 'cover.png'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('reports nested chapter directories and ignores empty chapters', () {
      final temp = Directory.systemTemp.createTempSync('comic_layout_');
      try {
        final empty = Directory(FilePath.join(temp.path, 'Empty'))
          ..createSync();
        File(
          FilePath.join(empty.path, 'metadata.json'),
        ).writeAsStringSync('{}');
        final chapter = Directory(FilePath.join(temp.path, 'Chapter'))
          ..createSync();
        Directory(FilePath.join(chapter.path, 'Nested')).createSync();

        final layout = ComicFileSystemLayout.inspect(temp);

        expect(layout.hasImages, isFalse);
        expect(layout.chapters, isEmpty);
        expect(layout.nestedDirectories, hasLength(1));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('unwraps one top-level directory while ignoring archive metadata', () {
      final temp = Directory.systemTemp.createTempSync('comic_layout_');
      try {
        Directory(FilePath.join(temp.path, '__MACOSX')).createSync();
        final root = Directory(FilePath.join(temp.path, 'Book'))..createSync();
        File(FilePath.join(root.path, '1.jpg')).writeAsBytesSync([1]);

        final layout = ComicFileSystemLayout.inspect(
          temp,
          unwrapSingleDirectory: true,
        );

        expect(layout.root.name, 'Book');
        expect(layout.rootPages.single.name, '1.jpg');
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test('async inspection uses the same layout rules', () async {
      final temp = Directory.systemTemp.createTempSync('comic_layout_');
      try {
        final chapter = Directory(FilePath.join(temp.path, 'Chapter'))
          ..createSync();
        File(FilePath.join(chapter.path, 'cover.jpg')).writeAsBytesSync([1]);
        File(FilePath.join(chapter.path, '1.jpg')).writeAsBytesSync([1]);

        final layout = await ComicFileSystemLayout.inspectAsync(temp);

        expect(layout.useChapterDirectories, isTrue);
        expect(layout.inferredCover?.name, 'cover.jpg');
        expect(layout.chapters.single.pages.single.name, '1.jpg');
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
}
