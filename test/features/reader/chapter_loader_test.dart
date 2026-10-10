import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:venera_next/network/request_scope.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_source/source_images_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/reader/chapter_loader.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/waterfall_controller.dart';
import 'package:venera_next/features/reader/waterfall_flow.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/js_engine.dart';
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
  late String root;
  late LocalManager manager;
  var onlineCalls = 0;
  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('venera-chapter-loader-');
    root = temporary.path;
    App.dataPath = root;
    App.cachePath = root;
    Log.isMuted = true;
    LocalManager.current?.dispose();
    LocalManager(initializeSources: () async {});
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
    LocalManager.current?.dispose();
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
    RequestScope? scope,
    bool local = false,
    int chapter = 1,
    ComicChapters chapters = _chapters,
    void Function()? onOnlineFallback,
  }) => loadReaderChapterImages(
    scope: scope,
    comicId: 'book',
    type: local ? ComicType.local : _type,
    chapter: chapter,
    chapters: chapters,
    onOnlineFallback: onOnlineFallback,
  );

  test('cancelled owner never starts a source request', () async {
    final scope = RequestScope()..cancel();
    await expectLater(load(scope: scope), throwsA(isA<RequestCancelled>()));
    expect(onlineCalls, 0);
    scope.dispose();
  });

  test('a missing source exposes a structured unsupported result', () async {
    ComicSourceManager().remove(_key);
    await expectLater(
      load(),
      throwsA(
        isA<OperationFailure>()
            .having((error) => error.kind, 'kind', FailureKind.unsupported)
            .having((error) => error.stackTrace, 'stack', isNotNull),
      ),
    );
    expect(onlineCalls, 0);
  });

  test('cancellation waits for source and suppresses late recovery', () async {
    await add(writeImage: false);
    final response = Completer<Res<List<String>>>();
    final started = Completer<RequestScope>();
    ComicSourceManager().remove(_key);
    ComicSourceManager().add(
      source((id, ep) {
        started.complete(RequestScope.current!);
        return response.future;
      }),
    );
    final owner = RequestScope();
    var notified = false;
    final pending = load(scope: owner, onOnlineFallback: () => notified = true);
    var settled = false;
    final expectation = expectLater(
      pending,
      throwsA(isA<RequestCancelled>()),
    ).then((_) => settled = true);
    final child = await started.future;
    owner.cancel();
    await pumpEventQueue();
    expect(settled, false);
    expect(child.cancelToken.isCancelled, true);
    response.complete(Res(['https://example.invalid/late.jpg']));
    await expectation;
    expect(notified, false);
    owner.dispose();
  });

  test('one owner cancellation leaves another chapter request alive', () async {
    final responses = <Completer<Res<List<String>>>>[];
    ComicSourceManager().remove(_key);
    ComicSourceManager().add(
      source((id, ep) {
        final response = Completer<Res<List<String>>>();
        responses.add(response);
        return response.future;
      }),
    );
    final first = RequestScope();
    final second = RequestScope();
    final cancelled = expectLater(
      load(scope: first),
      throwsA(isA<RequestCancelled>()),
    );
    final remaining = load(scope: second);
    expect(responses.length, 2);
    first.cancel();
    responses[1].complete(Res(['second.jpg']));
    expect(await remaining, ['second.jpg']);
    responses[0].complete(Res(['first.jpg']));
    await cancelled;
    first.dispose();
    second.dispose();
  });

  test(
    'structured late source failure keeps original cause and stack',
    () async {
      final response = Completer<Res<List<String>>>();
      final failure = StateError('late source cause');
      final stack = StackTrace.fromString('original chapter source stack');
      ComicSourceManager().remove(_key);
      ComicSourceManager().add(source((id, ep) => response.future));
      final owner = RequestScope();
      final checked = load(scope: owner).then<void>(
        (_) => fail('unexpected success'),
        onError: (Object error, StackTrace actualStack) {
          expect(error, same(failure));
          expect(actualStack, same(stack));
        },
      );
      owner.cancel();
      response.complete(Res.fromException(failure, stack));
      await checked;
      owner.dispose();
    },
  );

  test(
    'downloaded chapter remains readable after reopening the database',
    () async {
      await add();
      final before = await load();
      LocalManager.current?.dispose();
      LocalManager(initializeSources: () async {});
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
      LocalManager.current?.dispose();
      LocalManager(initializeSources: () async {});
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
        throwsA(
          isA<OperationFailure>().having(
            (error) => error.message,
            'message',
            'offline',
          ),
        ),
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

  for (final reject in [false, true]) {
    test(
      'waterfall exit joins production chapter JS Promise; reject=$reject',
      () async {
        App.version = 'test';
        App.isInitialized = false;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        final engine = JsEngine();
        await engine.init();
        final callbacks = JsCallbackScope();
        engine.runCode('''
        void (globalThis.nativeChapterCalls = 0);
        void (ComicSource.sources.$_key = {comic: {
          loadEp: (id, episode) => {
            ++nativeChapterCalls;
            return new Promise((resolve, reject) => {
              globalThis.finishNativeChapter = resolve;
              globalThis.failNativeChapter = reject;
            });
          }
        }});
      ''');
        final parser = SourceImagesParser(
          SourceParserContext(
            key: _key,
            name: 'Chapter completion test',
            callbacks: callbacks,
          ),
        );
        ComicSourceManager().remove(_key);
        ComicSourceManager().add(source(parser.parseLoadComicPagesFunc()!));
        final work = ImageWork();
        final controller =
            WaterfallController(
              maxChapter: 2,
              imageWork: work,
              load: (chapter, scope) => load(chapter: chapter, scope: scope),
              chapterId: (chapter) => _chapters.ids.elementAt(chapter - 1),
              onChanged: () {},
              onPreviousError: (_, _) => fail('unexpected UI error'),
            )..initialize(
              WaterfallChapterSegment(
                chapter: 1,
                eid: 'first',
                images: ['first-page'],
              ),
            );
        final loading = controller.ensureAfter(current: 1, threshold: 1);
        expect(engine.runCode('nativeChapterCalls'), 1);
        var prepared = false;
        final preparation = work.prepareForExit();
        final checked = reject
            ? expectLater(
                preparation,
                throwsA(
                  isA<ImageWorkFailure>().having(
                    (error) => error.failures.map((entry) => entry.error),
                    'original JS rejection',
                    ['Connection reset by peer'],
                  ),
                ),
              ).then((_) => prepared = true)
            : preparation.then((release) {
                prepared = true;
                release();
              });
        await loading;
        await pumpEventQueue();
        expect(prepared, false);
        engine.runCode(
          reject
              ? 'void failNativeChapter("Connection reset by peer")'
              : 'void finishNativeChapter({images: ["late-native-page"]})',
        );
        await checked;
        expect(engine.runCode('nativeChapterCalls'), 1);
        expect(controller.flow.lastChapter, 1);
        expect(controller.afterError, isNull);
        await controller.dispose();
        callbacks.dispose();
        engine.dispose();
      },
      skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
    );
  }
}
