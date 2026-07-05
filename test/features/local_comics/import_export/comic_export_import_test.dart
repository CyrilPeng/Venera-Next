import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';

void main() {
  group('ComicExportInfo', () {
    test('toJson should return correct map', () {
      final info = ComicExportInfo(
        id: '123',
        title: 'Test Comic',
        subtitle: 'Author',
        tags: ['tag1', 'tag2'],
        directory: 'test_comic',
        chapters: {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'},
        cover: 'cover.jpg',
        comicType: 12345,
        downloadedChapters: ['ch1', 'ch2'],
        createdAt: 1704067200000,
        sourceDirectory: '123_12345',
      );

      final json = info.toJson();
      expect(json['id'], '123');
      expect(json['title'], 'Test Comic');
      expect(json['subtitle'], 'Author');
      expect(json['tags'], ['tag1', 'tag2']);
      expect(json['directory'], 'test_comic');
      expect(json['chapters'], {'ch1': 'Chapter 1', 'ch2': 'Chapter 2'});
      expect(json['cover'], 'cover.jpg');
      expect(json['comicType'], 12345);
      expect(json['downloadedChapters'], ['ch1', 'ch2']);
      expect(json['createdAt'], 1704067200000);
      expect(json['sourceDirectory'], '123_12345');
    });

    test('toJson should handle empty lists and maps', () {
      final info = ComicExportInfo(
        id: '456',
        title: 'Empty Comic',
        subtitle: '',
        tags: [],
        directory: 'empty_comic',
        chapters: {},
        cover: '',
        comicType: 0,
        downloadedChapters: [],
        createdAt: 0,
        sourceDirectory: '456_0',
      );

      final json = info.toJson();
      expect(json['tags'], isEmpty);
      expect(json['chapters'], isEmpty);
      expect(json['downloadedChapters'], isEmpty);
    });

    test('fromJson should deserialize valid JSON correctly', () {
      final json = {
        'id': '789',
        'title': 'Deserialized Comic',
        'subtitle': 'Writer',
        'tags': ['sci-fi', 'drama'],
        'directory': 'deser_comic',
        'chapters': {'c1': 'Chapter A', 'c2': 'Chapter B'},
        'cover': 'cover.png',
        'comicType': 99,
        'downloadedChapters': ['c1'],
        'createdAt': 1700000000000,
        'sourceDirectory': '789_99',
      };

      final info = ComicExportInfo.fromJson(json);
      expect(info.id, '789');
      expect(info.title, 'Deserialized Comic');
      expect(info.subtitle, 'Writer');
      expect(info.tags, ['sci-fi', 'drama']);
      expect(info.directory, 'deser_comic');
      expect(info.chapters, {'c1': 'Chapter A', 'c2': 'Chapter B'});
      expect(info.cover, 'cover.png');
      expect(info.comicType, 99);
      expect(info.downloadedChapters, ['c1']);
      expect(info.createdAt, 1700000000000);
      expect(info.sourceDirectory, '789_99');
    });

    test('fromJson should handle empty lists and maps', () {
      final json = {
        'id': '0',
        'title': 'Empty',
        'subtitle': '',
        'tags': <String>[],
        'directory': 'dir',
        'chapters': <String, String>{},
        'cover': '',
        'comicType': 0,
        'downloadedChapters': <String>[],
        'createdAt': 0,
        'sourceDirectory': '0_0',
      };

      final info = ComicExportInfo.fromJson(json);
      expect(info.tags, isEmpty);
      expect(info.chapters, isEmpty);
      expect(info.downloadedChapters, isEmpty);
    });

    test('toJson -> fromJson round trip should preserve data', () {
      final original = ComicExportInfo(
        id: 'round-trip',
        title: 'Round Trip Comic',
        subtitle: 'Testing',
        tags: ['test', 'round-trip'],
        directory: 'rt_comic',
        chapters: {'rt1': 'RT Chapter 1'},
        cover: 'rt.jpg',
        comicType: 42,
        downloadedChapters: ['rt1'],
        createdAt: 1234567890,
        sourceDirectory: 'round-trip_42',
      );

      final json = original.toJson();
      final restored = ComicExportInfo.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.subtitle, original.subtitle);
      expect(restored.tags, original.tags);
      expect(restored.directory, original.directory);
      expect(restored.chapters, original.chapters);
      expect(restored.cover, original.cover);
      expect(restored.comicType, original.comicType);
      expect(restored.downloadedChapters, original.downloadedChapters);
      expect(restored.createdAt, original.createdAt);
      expect(restored.sourceDirectory, original.sourceDirectory);
    });

    test(
      'fromJson should throw FormatException on wrong type for String field',
      () {
        final json = {
          'id': 123, // should be String
          'title': 'Test',
          'subtitle': '',
          'tags': <String>[],
          'directory': 'dir',
          'chapters': <String, String>{},
          'cover': '',
          'comicType': 0,
          'downloadedChapters': <String>[],
          'createdAt': 0,
          'sourceDirectory': '0_0',
        };

        expect(
          () => ComicExportInfo.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"id" must be a String'),
            ),
          ),
        );
      },
    );

    test(
      'fromJson should throw FormatException on wrong type for int field',
      () {
        final json = {
          'id': '1',
          'title': 'Test',
          'subtitle': '',
          'tags': <String>[],
          'directory': 'dir',
          'chapters': <String, String>{},
          'cover': '',
          'comicType': 'not-an-int', // should be int
          'downloadedChapters': <String>[],
          'createdAt': 0,
          'sourceDirectory': '1_0',
        };

        expect(
          () => ComicExportInfo.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"comicType" must be an int'),
            ),
          ),
        );
      },
    );

    test(
      'fromJson should throw FormatException on wrong type for List field',
      () {
        final json = {
          'id': '1',
          'title': 'Test',
          'subtitle': '',
          'tags': 'not-a-list', // should be List
          'directory': 'dir',
          'chapters': <String, String>{},
          'cover': '',
          'comicType': 0,
          'downloadedChapters': <String>[],
          'createdAt': 0,
          'sourceDirectory': '1_0',
        };

        expect(
          () => ComicExportInfo.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"tags" must be a List'),
            ),
          ),
        );
      },
    );

    test(
      'fromJson should throw FormatException on wrong type for Map field',
      () {
        final json = {
          'id': '1',
          'title': 'Test',
          'subtitle': '',
          'tags': <String>[],
          'directory': 'dir',
          'chapters': 'not-a-map', // should be Map
          'cover': '',
          'comicType': 0,
          'downloadedChapters': <String>[],
          'createdAt': 0,
          'sourceDirectory': '1_0',
        };

        expect(
          () => ComicExportInfo.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"chapters" must be a Map'),
            ),
          ),
        );
      },
    );

    test('fromJson should throw FormatException on non-String list item', () {
      final json = {
        'id': '1',
        'title': 'Test',
        'subtitle': '',
        'tags': [123], // items should be String
        'directory': 'dir',
        'chapters': <String, String>{},
        'cover': '',
        'comicType': 0,
        'downloadedChapters': <String>[],
        'createdAt': 0,
        'sourceDirectory': '1_0',
      };

      expect(
        () => ComicExportInfo.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('items in "tags" must be Strings'),
          ),
        ),
      );
    });

    test('fromJson should throw FormatException on invalid map value type', () {
      final json = {
        'id': '1',
        'title': 'Test',
        'subtitle': '',
        'tags': <String>[],
        'directory': 'dir',
        'chapters': {'c1': 123}, // values should be String or Map
        'cover': '',
        'comicType': 0,
        'downloadedChapters': <String>[],
        'createdAt': 0,
        'sourceDirectory': '1_0',
      };

      expect(
        () => ComicExportInfo.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"chapters" must be Strings or Maps'),
          ),
        ),
      );
    });

    test('fromJson should handle grouped chapters', () {
      final json = {
        'id': '1',
        'title': 'Grouped Comic',
        'subtitle': '',
        'tags': <String>[],
        'directory': 'dir',
        'chapters': {
          'Volume 1': {'c1': 'Chapter 1', 'c2': 'Chapter 2'},
          'Volume 2': {'c3': 'Chapter 3'},
        },
        'cover': 'cover.jpg',
        'comicType': 0,
        'downloadedChapters': <String>['c1', 'c2'],
        'createdAt': 0,
        'sourceDirectory': '1_0',
      };

      final info = ComicExportInfo.fromJson(json);
      expect(info.chapters, isA<Map<String, dynamic>>());
      expect(info.chapters['Volume 1'], isA<Map>());
      expect((info.chapters['Volume 1'] as Map)['c1'], 'Chapter 1');
      expect((info.chapters['Volume 2'] as Map)['c3'], 'Chapter 3');
    });

    test('toJson -> fromJson round trip should preserve grouped chapters', () {
      final original = ComicExportInfo(
        id: 'grouped',
        title: 'Grouped Comic',
        subtitle: '',
        tags: [],
        directory: 'dir',
        chapters: {
          'Vol 1': {'c1': 'Ch 1', 'c2': 'Ch 2'},
          'Vol 2': {'c3': 'Ch 3'},
        },
        cover: 'cover.jpg',
        comicType: 0,
        downloadedChapters: ['c1', 'c2', 'c3'],
        createdAt: 0,
        sourceDirectory: 'grouped_0',
      );

      final json = original.toJson();
      final restored = ComicExportInfo.fromJson(json);

      expect(restored.chapters, original.chapters);
    });
  });

  group('ComicExportMetadata', () {
    test('toJson should return correct structure', () {
      final metadata = ComicExportMetadata(
        version: 1,
        exportTime: '2026-05-12T00:00:00Z',
        totalCount: 1,
        comics: [
          ComicExportInfo(
            id: '123',
            title: 'Test Comic',
            subtitle: 'Author',
            tags: [],
            directory: 'test_comic',
            chapters: {},
            cover: 'cover.jpg',
            comicType: 12345,
            downloadedChapters: [],
            createdAt: 1704067200000,
            sourceDirectory: '123_12345',
          ),
        ],
      );

      final json = metadata.toJson();
      expect(json['version'], 1);
      expect(json['exportTime'], '2026-05-12T00:00:00Z');
      expect(json['totalCount'], 1);
      expect(json['comics'], isA<List>());
      expect((json['comics'] as List).length, 1);
    });

    test('toJson should serialize comics list correctly', () {
      final metadata = ComicExportMetadata(
        version: 2,
        exportTime: '2026-01-01T12:00:00Z',
        totalCount: 2,
        comics: [
          ComicExportInfo(
            id: '1',
            title: 'Comic 1',
            subtitle: 'Sub1',
            tags: ['action'],
            directory: 'comic1',
            chapters: {'c1': 'Ch 1'},
            cover: 'c1.jpg',
            comicType: 100,
            downloadedChapters: ['c1'],
            createdAt: 1000000,
            sourceDirectory: '1_100',
          ),
          ComicExportInfo(
            id: '2',
            title: 'Comic 2',
            subtitle: 'Sub2',
            tags: ['romance'],
            directory: 'comic2',
            chapters: {'c2': 'Ch 2'},
            cover: 'c2.jpg',
            comicType: 200,
            downloadedChapters: ['c2'],
            createdAt: 2000000,
            sourceDirectory: '2_200',
          ),
        ],
      );

      final json = metadata.toJson();
      expect(json['version'], 2);
      expect(json['totalCount'], 2);

      final comicsList = json['comics'] as List;
      expect(comicsList.length, 2);

      final firstComic = comicsList[0] as Map<String, dynamic>;
      expect(firstComic['id'], '1');
      expect(firstComic['title'], 'Comic 1');
      expect(firstComic['tags'], ['action']);

      final secondComic = comicsList[1] as Map<String, dynamic>;
      expect(secondComic['id'], '2');
      expect(secondComic['title'], 'Comic 2');
      expect(secondComic['tags'], ['romance']);
    });

    test('toJson should handle empty comics list', () {
      final metadata = ComicExportMetadata(
        version: 1,
        exportTime: '2026-05-12T00:00:00Z',
        totalCount: 0,
        comics: [],
      );

      final json = metadata.toJson();
      expect(json['version'], 1);
      expect(json['totalCount'], 0);
      expect(json['comics'], isEmpty);
    });
  });
}
