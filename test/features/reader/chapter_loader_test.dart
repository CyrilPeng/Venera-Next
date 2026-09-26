import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

const _key = 'local_chapter_test';
final _type = ComicType.fromKey(_key);
const _chapters = ComicChapters({'first': 'First', 'second': 'Second'});

ComicSource source(LoadComicPagesFunc load) => ComicSource(
  'Test',
  _key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  load,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

void main() {
  late Directory temporary;
  late String root;
  late LocalManager manager;
  var onlineCalls = 0;
  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('venera-chapter-loader-');
    root = temporary.path;
    App.dataPath = root;
    App.cachePath = root;
    Log.isMuted = true;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    onlineCalls = 0;
    ComicSourceManager().add(
      source((id, ep) async {
        onlineCalls++;
        return Res(['https://example.invalid/${ep!}.jpg']);
      }),
    );
  });
  tearDown(() {
    ComicSourceManager().remove(_key);
    LocalManager.resetForTesting();
    Log.isMuted = false;
    temporary.deleteSync(recursive: true);
  });

  Future<void> add({bool local = false, bool writeImage = true}) async {
    final directory = Directory('${manager.path}/book/first');
    directory.createSync(recursive: true);
    if (writeImage) File('${directory.path}/1.jpg').writeAsBytesSync([1]);
    await manager.add(
      LocalComic(
        id: 'book',
        title: 'Book',
        subtitle: '',
        tags: const [],
        directory: 'book',
        chapters: _chapters,
        cover: '',
        comicType: local ? ComicType.local : _type,
        downloadedChapters: ['first'],
        createdAt: DateTime(2026),
      ),
    );
  }

  Future<List<String>> load({
    bool local = false,
    int chapter = 1,
    ComicChapters chapters = _chapters,
    void Function()? onOnlineFallback,
  }) => loadReaderChapterImages(
    comicId: 'book',
    type: local ? ComicType.local : _type,
    chapter: chapter,
    chapters: chapters,
    onOnlineFallback: onOnlineFallback,
  );

  test(
    'downloaded chapter remains readable after reopening the database',
    () async {
      await add();
      final before = await load();
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      manager = LocalManager();
      await manager.init();
      expect(await load(), before);
      expect(onlineCalls, 0);
    },
  );

  test(
    'uses stable chapter ID when source and download order differ',
    () async {
      await add();
      final images = await load(
        chapter: 2,
        chapters: const ComicChapters({'second': 'Second', 'first': 'First'}),
      );
      expect(images.single, endsWith('first${Platform.pathSeparator}1.jpg'));
      expect(onlineCalls, 0);
      expect(manager.find('book', _type)!.chapters!.ids, ['first', 'second']);
    },
  );

  test(
    'missing chapter after restart falls back online without deleting records',
    () async {
      await add();
      Directory('${manager.path}/book/first').deleteSync(recursive: true);
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      manager = LocalManager();
      await manager.init();
      var notified = 0;
      expect(await load(onOnlineFallback: () => notified++), [
        'https://example.invalid/first.jpg',
      ]);
      expect(onlineCalls, 1);
      expect(notified, 1);
      expect(manager.find('book', _type)!.downloadedChapters, ['first']);
      expect(Directory('${manager.path}/book/first').existsSync(), false);
    },
  );

  test('empty downloaded chapter can recover online', () async {
    await add(writeImage: false);
    expect(await load(), ['https://example.invalid/first.jpg']);
    expect(onlineCalls, 1);
  });

  test(
    'online recovery errors are reported and keep download records',
    () async {
      await add(writeImage: false);
      ComicSourceManager().remove(_key);
      ComicSourceManager().add(
        source((id, ep) async => const Res.error('offline')),
      );
      var notified = false;
      await expectLater(
        load(onOnlineFallback: () => notified = true),
        throwsA('offline'),
      );
      expect(notified, false);
      expect(manager.find('book', _type)!.downloadedChapters, ['first']);
    },
  );

  test(
    'local imports show a repairable error without creating empty directories',
    () async {
      await add(local: true);
      final missing = Directory('${manager.path}/book/first');
      missing.deleteSync(recursive: true);
      await expectLater(
        load(local: true),
        throwsA(isA<LocalComicFilesUnavailable>()),
      );
      expect(missing.existsSync(), false);
      expect(onlineCalls, 0);
      expect(manager.find('book', ComicType.local), isNotNull);
    },
  );
}
