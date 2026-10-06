import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_comic_parser.dart';
import 'package:venera_next/features/comic_source/source_images_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorites_provider.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

const _key = 'favorite_provider_test';
final _type = ComicType.fromKey(_key);
const _chapters = ComicChapters({'second': 'Second', 'first': 'First'});

ImageFavorite _image({
  int page = 1,
  String imageKey = 'known-image',
  String eid = 'first',
  int ep = 1,
  String sourceKey = _key,
}) =>
    ImageFavorite(page, imageKey, false, eid, 'book', ep, sourceKey, 'Chapter');

ComicSource _source(LoadComicPagesFunc? load, {LoadComicFunc? info}) =>
    ComicSource(
      'Test',
      _key,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      info,
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

void source(LoadComicPagesFunc? load, {LoadComicFunc? info}) {
  ComicSourceManager().remove(_key);
  ComicSourceManager().add(
    _source(
      load,
      info:
          info ??
          (_) async => Res(
            ComicDetails.fromJson({
              'title': 'Book',
              'cover': '',
              'tags': <String, List<String>>{},
              'chapters': _chapters.toJson(),
              'sourceKey': _key,
              'comicId': 'book',
            }),
          ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nativeAvailable = true;
  try {
    if (Platform.isWindows) {
      final path = Directory('build/windows/x64/runner/Release').absolute.path;
      DynamicLibrary.open('$path/flutter_windows.dll');
      DynamicLibrary.open('$path/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
  } catch (_) {
    nativeAvailable = false;
  }
  late Directory temporary;
  late LocalManager manager;
  late String previousDataPath, previousCachePath;
  late bool previousLogMuted;
  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });
  setUp(() async {
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousLogMuted = Log.isMuted;
    temporary = Directory.systemTemp.createTempSync('favorite-provider-');
    App.dataPath = temporary.path;
    App.cachePath = temporary.path;
    Log.isMuted = true;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    source((_, _) async => const Res(['new-image']));
  });
  tearDown(() {
    ComicSourceManager().remove(_key);
    LocalManager.resetForTesting();
    Log.isMuted = previousLogMuted;
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    temporary.deleteSync(recursive: true);
  });

  Future<void> add({
    ComicChapters? chapters = _chapters,
    List<String> downloaded = const ['first', 'second'],
    bool local = false,
  }) async {
    for (final chapter in chapters?.ids ?? ['']) {
      final directory = Directory('${manager.path}/book/$chapter')
        ..createSync(recursive: true);
      File(
        '${directory.path}/1.jpg',
      ).writeAsBytesSync([chapter == 'second' ? 2 : 1]);
      File('${directory.path}/2.jpg').writeAsBytesSync([3]);
    }
    await manager.add(
      LocalComic(
        id: 'book',
        title: 'Book',
        subtitle: '',
        tags: const [],
        directory: 'book',
        chapters: chapters,
        cover: '',
        comicType: local ? ComicType.local : _type,
        downloadedChapters: downloaded,
        createdAt: DateTime(2026),
      ),
    );
  }

  Future<Uint8List> read(
    ImageFavoritesProvider provider, {
    RequestScope? owner,
    void Function(ImageChunkEvent)? onProgress,
  }) async {
    final scope = owner ?? RequestScope();
    try {
      return await provider.readBytes(
        checkStop: scope.check,
        cancelSignal: scope.whenCancelled,
        onProgress: onProgress,
      );
    } finally {
      if (owner == null) scope.dispose();
    }
  }

  test(
    'downloaded images use comic ID, stable chapter ID and one-based pages',
    () async {
      await add();
      final first = _Provider(_image());
      final last = _Provider(_image(page: 2));
      expect(await read(first), [1]);
      expect(await read(last), [3]);
      expect(first.networkKeys, isEmpty);
      expect(last.networkKeys, isEmpty);
    },
  );

  test('chapterless local images and raw file paths remain readable', () async {
    await add(chapters: null, local: true);
    final provider = _Provider(_image(page: 2, eid: '', sourceKey: 'local'));
    expect(await read(provider), [3]);
    expect(provider.networkKeys, isEmpty);
  });

  test(
    'only missing legacy chapter IDs use the saved one-based ordinal',
    () async {
      await add();
      final firstOrdinal = _Provider(_image(eid: '', ep: 1));
      final secondOrdinal = _Provider(_image(eid: '', ep: 2));
      expect(await read(firstOrdinal), [2]);
      expect(await read(secondOrdinal), [1]);
      final missingID = _Provider(_image(eid: 'removed', ep: 1));
      expect(await read(missingID), [9]);
      expect(missingID.networkKeys, ['known-image']);
      await expectLater(
        read(_Provider(_image(eid: '', ep: 0))),
        throwsA(isA<RangeError>()),
      );
    },
  );

  test(
    'uncommitted downloaded chapter files cannot replace the remote image',
    () async {
      await add(downloaded: ['second']);
      final provider = _Provider(_image());
      expect(await read(provider), [9]);
      expect(provider.networkKeys, ['known-image']);
    },
  );

  test('missing directory and incomplete local pages recover online', () async {
    await add();
    Directory('${manager.path}/book/first').deleteSync(recursive: true);
    final missingDirectory = _Provider(_image());
    expect(await read(missingDirectory), [9]);
    final missingPage = _Provider(_image(eid: 'second', page: 3));
    expect(await read(missingPage), [9]);
    expect(missingDirectory.networkKeys, ['known-image']);
    expect(missingPage.networkKeys, ['known-image']);
  });

  test('a file removed after listing recovers online', () async {
    await add();
    final file = File('${manager.path}/book/first/1.jpg');
    final provider = _Provider(_image());
    final racing = _ReadFile(file.path, () async {
      file.deleteSync();
      return file.readAsBytes();
    });
    await _withReadFile(racing, () async {
      expect(await read(provider), [9]);
    });
    expect(provider.networkKeys, ['known-image']);
  });

  test('permission failure stays observable without fallback', () async {
    await add();
    final path = '${manager.path}/book/first/1.jpg';
    final error = FileSystemException(
      'permission denied',
      path,
      const OSError('denied', 5),
    );
    final provider = _Provider(_image());
    final denied = _ReadFile(path, () => Future.error(error));
    await _withReadFile(denied, () async {
      await expectLater(read(provider), throwsA(same(error)));
    });
    expect(provider.networkKeys, isEmpty);
  });

  test(
    'cancelled local read keeps its original late failure and never falls back',
    () async {
      await add();
      final path = '${manager.path}/book/first/1.jpg';
      final started = Completer<void>();
      final result = Completer<Uint8List>();
      final error = PathNotFoundException(
        path,
        const OSError('removed while reading', 2),
      );
      final stack = StackTrace.fromString('original local read stack');
      final provider = _Provider(_image());
      final owner = RequestScope();
      final delayed = _ReadFile(path, () {
        started.complete();
        return result.future;
      });
      await _withReadFile(delayed, () async {
        final checked = read(provider, owner: owner).then<void>(
          (_) => fail('unexpected success'),
          onError: (Object actual, StackTrace actualStack) {
            expect(actual, same(error));
            expect(actualStack, same(stack));
          },
        );
        await started.future;
        owner.cancel();
        result.completeError(error, stack);
        await checked;
      });
      expect(provider.networkKeys, isEmpty);
      owner.dispose();
    },
  );

  test(
    'new cache identity separates imported pages and chapters and ignores old keys',
    () async {
      final image = _image(imageKey: '', eid: '');
      final a = _Provider(image);
      final b = _Provider(image.copyWith(page: 2));
      final c = _Provider(image.copyWith(ep: 2));
      expect({a.key, b.key, c.key}, hasLength(3));
      final oldKey = 'ImageFavorites @$_key@book@';
      final oldCache = File(
        '${App.cachePath}/image_favorites/${md5.convert(oldKey.codeUnits)}',
      );
      oldCache.createSync(recursive: true);
      oldCache.writeAsBytesSync([99]);
      expect(await a.readFromCache(), isNull);
      await a.writeToCache(Uint8List.fromList([1]));
      await b.writeToCache(Uint8List.fromList([2]));
      await c.writeToCache(Uint8List.fromList([3]));
      expect(await a.readFromCache(), [1]);
      expect(await b.readFromCache(), [2]);
      expect(await c.readFromCache(), [3]);
      await ImageFavoritesProvider.deleteFromCache(a.imageFavorite);
      expect(await a.readFromCache(), isNull);
      expect(await b.readFromCache(), [2]);
    },
  );

  for (final page in [0, -1, 2]) {
    test(
      'invalid source page $page produces a range error without downloading',
      () async {
        final provider = _Provider(_image(page: page, imageKey: ''));
        await expectLater(read(provider), throwsA(isA<RangeError>()));
        expect(provider.networkKeys, isEmpty);
      },
    );
  }

  test(
    'missing source capability and legacy source errors are explicit',
    () async {
      source(null);
      await expectLater(
        read(_Provider(_image(imageKey: ''))),
        throwsA(isA<UnsupportedError>()),
      );
      source((_, _) async => const Res.error('offline'));
      await expectLater(
        read(_Provider(_image(imageKey: ''))),
        throwsA('offline'),
      );
    },
  );

  for (final reject in [false, true]) {
    test(
      'source cancellation joins the original call; reject=$reject',
      () async {
        final started = Completer<RequestScope>();
        final result = Completer<Res<List<String>>>();
        source((_, _) {
          started.complete(RequestScope.current!);
          return result.future;
        });
        final provider = _Provider(_image(imageKey: ''));
        final owner = RequestScope();
        final error = StateError('source failed after cancellation');
        final stack = StackTrace.fromString('original source failure stack');
        var settled = false;
        final checked = read(provider, owner: owner).then<void>(
          (_) => fail('unexpected success'),
          onError: (Object actual, StackTrace actualStack) {
            expect(actual, reject ? same(error) : isA<RequestCancelled>());
            if (reject) expect(actualStack, same(stack));
            settled = true;
          },
        );
        final child = await started.future;
        owner.cancel();
        await pumpEventQueue();
        expect(child.cancelToken.isCancelled, true);
        expect(settled, false);
        result.complete(
          reject ? Res.fromException(error, stack) : const Res(['late']),
        );
        await checked;
        expect(provider.networkKeys, isEmpty);
        expect(await provider.readFromCache(), isNull);
        owner.dispose();
      },
    );
  }

  test(
    'explicit cancellation interrupts a silent image stream and waits for cleanup',
    () async {
      final started = Completer<void>();
      final cleanup = Completer<void>();
      final stream = StreamController<ImageDownloadProgress>(
        onListen: started.complete,
        onCancel: () => cleanup.future,
      );
      final provider = _Provider(_image())..stream = stream.stream;
      final owner = RequestScope();
      var settled = false;
      final checked = expectLater(
        read(provider, owner: owner),
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      await started.future;
      owner.cancel();
      await pumpEventQueue();
      expect(settled, false);
      cleanup.complete();
      await checked;
      expect(provider.networkKeys, ['known-image']);
      expect(await provider.readFromCache(), isNull);
      await stream.close();
      owner.dispose();
    },
  );

  test(
    'original bytes and progress are delivered through the shared read API',
    () async {
      final provider = _Provider(_image());
      final progress = <int>[];
      expect(
        await read(
          provider,
          onProgress: (event) => progress.add(event.cumulativeBytesLoaded),
        ),
        [9],
      );
      expect(progress, [1]);
      expect(await provider.readFromCache(), [9]);
    },
  );

  test(
    'chapterless imported favorites use null pages and the reader image chapter convention',
    () async {
      final pageChapters = <String?>[];
      source(
        (_, chapter) async {
          pageChapters.add(chapter);
          return const Res(['single-page']);
        },
        info: (_) async => Res(
          ComicDetails.fromJson({
            'title': 'Book',
            'cover': '',
            'tags': <String, List<String>>{},
            'sourceKey': _key,
            'comicId': 'book',
          }),
        ),
      );
      final previous = ImageDownloader.debugLoadComicImageUnwrapped;
      final imageChapters = <String>[];
      ImageDownloader.debugLoadComicImageUnwrapped =
          (key, source, id, chapter) {
            imageChapters.add(chapter);
            return Stream.value(
              ImageDownloadProgress(
                currentBytes: 1,
                totalBytes: 1,
                imageBytes: Uint8List.fromList([8]),
              ),
            );
          };
      try {
        expect(
          await read(ImageFavoritesProvider(_image(eid: '', imageKey: ''))),
          [8],
        );
        expect(pageChapters, [null]);
        expect(imageChapters, ['0']);
      } finally {
        ImageDownloader.debugLoadComicImageUnwrapped = previous;
      }
    },
  );

  test(
    'imported empty IDs resolve details, pages and image configuration through production parsers',
    () async {
      App.version = 'test';
      App.isInitialized = false;
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      final engine = JsEngine();
      await engine.init();
      final callbacks = JsCallbackScope();
      engine.runCode('''
      void (globalThis.importCalls = []);
      void (ComicSource.sources.$_key = {comic: {
        loadInfo: id => {
          importCalls.push('info:' + id);
          return {title:'Book', cover:'', tags:{}, chapters:{group:{second:'Second', first:'First'}}, extra:() => 42};
        },
        loadEp: (id, chapter) => {
          importCalls.push('pages:' + id + ':' + chapter);
          return {images:['page1','page2']};
        }
      }});
    ''');
      final context = SourceParserContext(
        key: _key,
        name: 'Imported favorites',
        callbacks: callbacks,
      );
      source(
        SourceImagesParser(context).parseLoadComicPagesFunc()!,
        info: SourceComicParser(context).parseLoadComicFunc(),
      );
      final previous = ImageDownloader.debugLoadComicImageUnwrapped;
      final downloads = <(String, String, String)>[];
      ImageDownloader.debugLoadComicImageUnwrapped =
          (key, source, id, chapter) {
            downloads.add((key, id, chapter));
            return Stream.value(
              ImageDownloadProgress(
                currentBytes: 1,
                totalBytes: 1,
                imageBytes: Uint8List.fromList([7]),
              ),
            );
          };
      try {
        final image = _image(imageKey: '', eid: '', ep: 2, page: 2);
        expect(await read(ImageFavoritesProvider(image)), [7]);
        expect(
          engine.runCode('importCalls.join(",")'),
          'info:book,pages:book:first',
        );
        expect(downloads, [('page2', 'book', 'first')]);
        expect(image.eid, '');
        expect(image.imageKey, '');
        expect(engine.debugOwnedReferenceCount, 0);
      } finally {
        ImageDownloader.debugLoadComicImageUnwrapped = previous;
        callbacks.dispose();
        engine.dispose();
      }
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );

  for (final reject in [false, true]) {
    test(
      'imported details cancellation joins original source and cannot start pages; reject=$reject',
      () async {
        App.version = 'test';
        App.isInitialized = false;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        final engine = JsEngine();
        await engine.init();
        final callbacks = JsCallbackScope();
        engine.runCode('''
        void (ComicSource.sources.$_key = {comic: {loadInfo: () => new Promise((resolve, reject) => {
          globalThis.finishFavoriteDetails = resolve;
          globalThis.failFavoriteDetails = reject;
        })}});
      ''');
        final context = SourceParserContext(
          key: _key,
          name: 'Imported cancellation',
          callbacks: callbacks,
        );
        var pagesCalled = false;
        source((_, _) async {
          pagesCalled = true;
          return const Res(['unexpected']);
        }, info: SourceComicParser(context).parseLoadComicFunc());
        final provider = _Provider(_image(imageKey: '', eid: ''));
        final owner = RequestScope();
        var settled = false;
        final checked = expectLater(
          read(provider, owner: owner),
          throwsA(reject ? 'late details failure' : isA<RequestCancelled>()),
        ).then((_) => settled = true);
        await pumpEventQueue();
        owner.cancel();
        await pumpEventQueue();
        expect(settled, false);
        engine.runCode(
          reject
              ? 'void failFavoriteDetails("late details failure")'
              : 'void finishFavoriteDetails({title:"Book",cover:"",tags:{},extra:() => 42})',
        );
        await checked;
        expect(pagesCalled, false);
        expect(provider.networkKeys, isEmpty);
        expect(engine.debugOwnedReferenceCount, 0);
        owner.dispose();
        callbacks.dispose();
        engine.dispose();
      },
      skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
    );
  }

  for (final reject in [false, true]) {
    test(
      'production QuickJS page Promise drains after save cancellation; reject=$reject',
      () async {
        App.version = 'test';
        App.isInitialized = false;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        final engine = JsEngine();
        await engine.init();
        final callbacks = JsCallbackScope();
        engine.runCode('''
        void (globalThis.favoritePageCalls = 0);
        void (ComicSource.sources.$_key = {comic: {loadEp: () => {
          ++favoritePageCalls;
          return new Promise((resolve, reject) => {
            globalThis.finishFavoritePage = resolve;
            globalThis.failFavoritePage = reject;
          });
        }}});
      ''');
        final parser = SourceImagesParser(
          SourceParserContext(
            key: _key,
            name: 'Favorite completion',
            callbacks: callbacks,
          ),
        );
        source(parser.parseLoadComicPagesFunc()!);
        final provider = _Provider(_image(imageKey: ''));
        final owner = RequestScope();
        var settled = false;
        final checked = expectLater(
          read(provider, owner: owner),
          throwsA(
            reject ? 'Connection reset by peer' : isA<RequestCancelled>(),
          ),
        ).then((_) => settled = true);
        await pumpEventQueue();
        expect(engine.runCode('favoritePageCalls'), 1);
        owner.cancel();
        await pumpEventQueue();
        expect(settled, false);
        engine.runCode(
          reject
              ? 'void failFavoritePage("Connection reset by peer")'
              : 'void finishFavoritePage({images: ["late-page"]})',
        );
        await checked;
        expect(engine.runCode('favoritePageCalls'), 1);
        expect(provider.networkKeys, isEmpty);
        owner.dispose();
        callbacks.dispose();
        engine.dispose();
      },
      skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
    );
  }
}

class _Provider extends ImageFavoritesProvider {
  _Provider(super.imageFavorite);
  final networkKeys = <String>[];
  Stream<ImageDownloadProgress>? stream;
  @override
  Stream<ImageDownloadProgress> loadComicImage(String imageKey) {
    networkKeys.add(imageKey);
    return stream ??
        Stream.value(
          ImageDownloadProgress(
            currentBytes: 1,
            totalBytes: 1,
            imageBytes: Uint8List.fromList([9]),
          ),
        );
  }
}

class _ReadFile implements File {
  _ReadFile(this.path, this.read);
  @override
  final String path;
  final Future<Uint8List> Function() read;
  @override
  Future<Uint8List> readAsBytes() => read();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<T> _withReadFile<T>(File file, Future<T> Function() action) {
  final parent = Zone.current;
  return IOOverrides.runZoned(
    action,
    createFile: (path) => p.equals(p.normalize(path), p.normalize(file.path))
        ? file
        : parent.run(() => File(path)),
  );
}
