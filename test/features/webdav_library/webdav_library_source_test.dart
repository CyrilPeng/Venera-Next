import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  late _FakeWebDavLibraryOps ops;

  setUp(() {
    ops = _FakeWebDavLibraryOps();
    WebDavLibrarySource.ops = ops;
    appdata.settings['webdavComicLibrary'] = [
      'https://example.com/dav',
      'user',
      'pass',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/manga/';
  });

  tearDown(() {
    WebDavLibrarySource.resetOps();
    appdata.settings['webdavComicLibrary'] = [];
    appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
  });

  test('loadComics lists directories and ignores archives', () async {
    ops.dirs['/manga/'] = const [
      WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      WebDavLibraryEntry(name: 'archive.cbz', isDirectory: false),
      WebDavLibraryEntry(name: '.DS_Store', isDirectory: false),
    ];
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComics(1);

    expect(result.success, isTrue);
    expect(result.data.single.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.subData, 1);
    expect(result.data.map((comic) => comic.title), ['Cat Eye']);
    expect(result.data.single.sourceKey, WebDavLibrarySource.sourceKey);
  });

  test(
    'loadComics keeps folder title and finds chapter cover from unmodifiable lists',
    () async {
      ops.dirs['/manga/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);

      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, '猫之眼[北条司]');
      expect(result.data.single.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
    },
  );

  test(
    'loadComics keeps folder title when metadata inspection fails',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: 'Cat Eye', isDirectory: true),
      ];
      ops.errors['/manga/Cat Eye/'] = UnsupportedError(
        'Cannot remove from an unmodifiable list',
      );

      final result = await WebDavLibrarySource.loadComics(1);

      expect(result.success, isTrue);
      expect(result.data.single.title, 'Cat Eye');
      expect(result.data.single.cover, '');
    },
  );

  test(
    'loadComicInfo detects chapter directories and uses the first page as cover',
    () async {
      ops.dirs['/manga/Cat Eye/'] = const [
        WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        WebDavLibraryEntry(name: '第02卷', isDirectory: true),
        WebDavLibraryEntry(name: 'book.cbz', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第01卷/'] = const [
        WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ];
      ops.dirs['/manga/Cat Eye/第02卷/'] = const [
        WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ];

      final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/Cat Eye/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
      });
      expect(ops.readPaths, ['/manga/Cat Eye/', '/manga/Cat Eye/第01卷/']);
    },
  );

  test(
    'loadComicInfo handles Chinese comic and chapter directories from unmodifiable lists',
    () async {
      ops.dirs['/manga/猫之眼[北条司]/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '第01卷', isDirectory: true),
        const WebDavLibraryEntry(name: '第02卷', isDirectory: true),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
        const WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
      ]);
      ops.dirs['/manga/猫之眼[北条司]/第02卷/'] = List.unmodifiable([
        const WebDavLibraryEntry(name: '001.webp', isDirectory: false),
      ]);

      final result = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');

      expect(result.success, isTrue);
      expect(result.data.cover, '/manga/猫之眼[北条司]/第01卷/001.jpg');
      expect(result.data.chapters!.allChapters, {
        '第01卷': '第01卷',
        '第02卷': '第02卷',
      });
      expect(ops.readPaths, ['/manga/猫之眼[北条司]/', '/manga/猫之眼[北条司]/第01卷/']);
    },
  );

  test('loadComicInfo uses root cover and root images when present', () async {
    ops.dirs['/manga/Cat Eye/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicInfo('Cat Eye');

    expect(result.success, isTrue);
    expect(result.data.cover, '/manga/Cat Eye/cover.jpg');
    expect(result.data.chapters, isNull);
  });

  test('loadComicPages returns chapter image paths in reading order', () async {
    ops.dirs['/manga/Cat Eye/第01卷/'] = const [
      WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ];

    final result = await WebDavLibrarySource.loadComicPages('Cat Eye', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/Cat Eye/第01卷/002.jpg',
      '/manga/Cat Eye/第01卷/010.jpg',
    ]);
  });

  test('loadComicPages handles Chinese directory paths', () async {
    ops.dirs['/manga/猫之眼[北条司]/第01卷/'] = List.unmodifiable([
      const WebDavLibraryEntry(name: '010.jpg', isDirectory: false),
      const WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
    ]);

    final result = await WebDavLibrarySource.loadComicPages('猫之眼[北条司]', '第01卷');

    expect(result.success, isTrue);
    expect(result.data, [
      '/manga/猫之眼[北条司]/第01卷/002.jpg',
      '/manga/猫之眼[北条司]/第01卷/010.jpg',
    ]);
  });

  test(
    'CBZ metadata enriches list and details and maps virtual chapter pages',
    () async {
      ops.dirs['/manga/'] = const [
        WebDavLibraryEntry(name: '猫之眼[北条司]', isDirectory: true),
      ];
      ops.dirs['/manga/猫之眼[北条司]/'] = const [
        WebDavLibraryEntry(name: 'metadata.JSON', isDirectory: false),
        WebDavLibraryEntry(name: 'ComicInfo.xml', isDirectory: false),
        WebDavLibraryEntry(name: 'cover.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0004.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0002.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0001.jpg', isDirectory: false),
        WebDavLibraryEntry(name: '0003.jpg', isDirectory: false),
      ];
      ops.textFiles['/manga/猫之眼[北条司]/metadata.JSON'] = jsonEncode({
        'title': '猫之眼',
        'author': '北条司',
        'tags': ['动作', '漫画'],
        'chapters': [
          {'title': '第01卷', 'start': 1, 'end': 2},
          {'title': '第02卷', 'start': 3, 'end': 4},
        ],
      });

      final comics = await WebDavLibrarySource.loadComics(1);
      final details = await WebDavLibrarySource.loadComicInfo('猫之眼[北条司]');
      final pages = await WebDavLibrarySource.loadComicPages(
        '猫之眼[北条司]',
        '__cbz_range_1',
      );

      expect(comics.success, isTrue);
      expect(comics.data.single.title, '猫之眼');
      expect(comics.data.single.subtitle, '北条司');
      expect(comics.data.single.tags, ['WebDAV', '动作', '漫画']);
      expect(comics.data.single.cover, '/manga/猫之眼[北条司]/cover.jpg');
      expect(details.success, isTrue);
      expect(details.data.title, '猫之眼');
      expect(details.data.subTitle, '北条司');
      expect(details.data.tags['Tags'], ['动作', '漫画']);
      expect(details.data.chapters!.allChapters, {
        '__cbz_range_0': '第01卷',
        '__cbz_range_1': '第02卷',
      });
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/猫之眼[北条司]/0003.jpg',
        '/manga/猫之眼[北条司]/0004.jpg',
      ]);
      expect(ops.textReadPaths, ['/manga/猫之眼[北条司]/metadata.JSON']);
    },
  );

  test(
    'CBZ metadata without chapters keeps root pages as one chapter',
    () async {
      ops.dirs['/manga/Flat Book/'] = const [
        WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
        WebDavLibraryEntry(name: '0002.webp', isDirectory: false),
        WebDavLibraryEntry(name: '0001.webp', isDirectory: false),
      ];
      ops.textFiles['/manga/Flat Book/metadata.json'] = jsonEncode({
        'title': 'Flat Export',
        'author': '',
        'tags': <String>[],
        'chapters': null,
      });

      final details = await WebDavLibrarySource.loadComicInfo('Flat Book');
      final pages = await WebDavLibrarySource.loadComicPages('Flat Book', null);

      expect(details.success, isTrue);
      expect(details.data.title, 'Flat Export');
      expect(details.data.chapters, isNull);
      expect(pages.success, isTrue);
      expect(pages.data, [
        '/manga/Flat Book/0001.webp',
        '/manga/Flat Book/0002.webp',
      ]);
    },
  );

  test('malformed CBZ metadata falls back to folder inference', () async {
    ops.dirs['/manga/Broken Book/'] = const [
      WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
      WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
    ];
    ops.textFiles['/manga/Broken Book/metadata.json'] = '{broken';

    final details = await WebDavLibrarySource.loadComicInfo('Broken Book');
    final pages = await WebDavLibrarySource.loadComicPages(
      'Broken Book',
      WebDavLibrarySource.rootChapterId,
    );

    expect(details.success, isTrue);
    expect(details.data.title, 'Broken Book');
    expect(details.data.chapters, isNull);
    expect(pages.success, isTrue);
    expect(pages.data, ['/manga/Broken Book/001.jpg']);
  });

  for (final invalidCase in <String, List<Map<String, Object>>>{
    'out-of-range': [
      {'title': 'Chapter 1', 'start': 1, 'end': 3},
    ],
    'overlapping': [
      {'title': 'Chapter 1', 'start': 1, 'end': 2},
      {'title': 'Chapter 2', 'start': 2, 'end': 2},
    ],
    'reversed': [
      {'title': 'Chapter 1', 'start': 2, 'end': 1},
    ],
  }.entries) {
    test(
      '${invalidCase.key} CBZ chapter ranges fall back to root pages',
      () async {
        ops.dirs['/manga/Invalid Book/'] = const [
          WebDavLibraryEntry(name: 'metadata.json', isDirectory: false),
          WebDavLibraryEntry(name: '002.jpg', isDirectory: false),
          WebDavLibraryEntry(name: '001.jpg', isDirectory: false),
        ];
        ops.textFiles['/manga/Invalid Book/metadata.json'] = jsonEncode({
          'title': 'Must Not Replace Folder Name',
          'author': 'Author',
          'tags': ['tag'],
          'chapters': invalidCase.value,
        });

        final details = await WebDavLibrarySource.loadComicInfo('Invalid Book');
        final pages = await WebDavLibrarySource.loadComicPages(
          'Invalid Book',
          null,
        );

        expect(details.success, isTrue);
        expect(details.data.title, 'Invalid Book');
        expect(details.data.chapters, isNull);
        expect(pages.success, isTrue);
        expect(pages.data, [
          '/manga/Invalid Book/001.jpg',
          '/manga/Invalid Book/002.jpg',
        ]);
      },
    );
  }

  test(
    'getImageLoadingConfig builds encoded URL and basic auth header',
    () async {
      final config = await WebDavLibrarySource.getImageLoadingConfig(
        '/manga/Cat Eye/第01卷/001.jpg',
        'Cat Eye',
        '第01卷',
      );

      expect(
        config['url'],
        'https://example.com/dav/manga/Cat%20Eye/%E7%AC%AC01%E5%8D%B7/001.jpg',
      );
      expect(config['headers'], {'authorization': 'Basic dXNlcjpwYXNz'});
    },
  );
}

class _FakeWebDavLibraryOps implements WebDavLibraryOps {
  final dirs = <String, List<WebDavLibraryEntry>>{};
  final errors = <String, Object>{};
  final textFiles = <String, String>{};
  final readPaths = <String>[];
  final textReadPaths = <String>[];

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    readPaths.add(remotePath);
    final error = errors[remotePath];
    if (error != null) throw error;
    return dirs[remotePath] ?? const [];
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String remotePath) async {
    textReadPaths.add(remotePath);
    final value = textFiles[remotePath];
    if (value == null) throw StateError('Missing text file: $remotePath');
    return value;
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {}
}
