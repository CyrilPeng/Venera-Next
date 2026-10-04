import 'dart:ffi';
import 'dart:io';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_images_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/request_scope.dart';

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

  group(
    'native image configuration ownership',
    () {
      late JsEngine engine;
      late SourceImagesParser parser;

      setUp(() async {
        App.version = 'test';
        App.isInitialized = false;
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        engine = JsEngine();
        await engine.init();
        parser = SourceImagesParser(
          SourceParserContext(
            key: 'image_config_test',
            name: 'Image configuration test',
            callbacks: JsCallbackScope(),
          ),
        );
        engine.runCode('''
        void (ComicSource.sources.image_config_test = {
          comic: {},
          callback: (value) => value + 1
        });
      ''');
      });

      tearDown(() {
        try {
          // flutter_qjs diagnoses every outstanding native Dart wrapper when
          // closing the runtime. This is stronger than checking a parse error.
          expect(engine.debugOwnedReferenceCount, 0);
          expect(engine.dispose, returnsNormally);
        } finally {
          Log.isMuted = false;
        }
      });

      void setHook(String hook, String function) {
        engine.runCode(
          'void (ComicSource.sources.image_config_test.comic.$hook = $function)',
        );
      }

      for (final reject in [false, true]) {
        test(
          'chapter page parser joins native Promise; reject=$reject',
          () async {
            setHook(
              'loadEp',
              '''(id, episode) => new Promise((resolve, reject) => {
            globalThis.completePages = resolve;
            globalThis.rejectPages = reject;
          })''',
            );
            final scope = RequestScope();
            var settled = false;
            Object? cause;
            final result = scope.runToCompletion(() async {
              final pages = await parser.parseLoadComicPagesFunc()!(
                'book',
                'ep',
              );
              settled = true;
              if (pages.error) {
                cause = pages.failure!.cause;
                Error.throwWithStackTrace(cause!, pages.failure!.stackTrace!);
              }
              return pages.data;
            });
            final checked = expectLater(
              result,
              throwsA(
                reject ? 'late page source failure' : isA<RequestCancelled>(),
              ),
            );
            scope.cancel();
            await pumpEventQueue();
            expect(settled, false);
            engine.runCode(
              reject
                  ? 'void rejectPages("late page source failure")'
                  : 'void completePages({images: ["late-page"]})',
            );
            await checked;
            expect(settled, true);
            expect(
              cause,
              reject ? 'late page source failure' : isA<RequestCancelled>(),
            );
            scope.dispose();
          },
        );
      }

      test('synchronous thumbnail config remains synchronous and owned', () {
        setHook('onThumbnailLoad', '''(url) => ({
        url,
        headers: {'Referer': 'test'},
        onResponse: ComicSource.sources.image_config_test.callback
      })''');
        final result = parser.parseThumbnailLoadingConfigFunc()!('thumbnail');
        expect(result, isNot(isA<Future>()));
        final config = result as Map<String, dynamic>;
        final callback = config['onResponse'] as JSInvokable;
        expect(config['url'], 'thumbnail');
        expect(config['headers'], {'Referer': 'test'});
        expect(callback([4]), 5);
        discardImageLoadingConfig(config);
        expect(() => callback([4]), throwsA(isA<JsDisposedError>()));
      });

      test('thumbnail Promise waits for the returned configuration', () async {
        setHook('onThumbnailLoad', '''(url) => new Promise(resolve => {
        globalThis.resolveImageConfiguration = resolve;
      })''');
        final result = parser.parseThumbnailLoadingConfigFunc()!('thumbnail');
        expect(result, isA<Future<Map<String, dynamic>>>());
        var completed = false;
        final pending = (result as Future<Map<String, dynamic>>).then((value) {
          completed = true;
          return value;
        });
        await pumpEventQueue();
        expect(completed, isFalse);
        engine.runCode('''void resolveImageConfiguration({
        url: 'async-thumbnail',
        onResponse: ComicSource.sources.image_config_test.callback
      })''');
        final config = await pending;
        expect(config['url'], 'async-thumbnail');
        expect((config['onResponse'] as JSInvokable)([7]), 8);
        discardImageLoadingConfig(config);
      });

      for (final asynchronous in [false, true]) {
        test(
          'image config retains usable callbacks; async=$asynchronous',
          () async {
            setHook(
              'onImageLoad',
              '''${asynchronous ? 'async ' : ''}(url, comic, episode) => ({
        url: url + '/' + comic + '/' + episode,
        onResponse: ComicSource.sources.image_config_test.callback
      })''',
            );
            final config = await parser.parseImageLoadingConfigFunc()!(
              'image',
              'comic',
              'episode',
            );
            expect(config['url'], 'image/comic/episode');
            expect((config['onResponse'] as JSInvokable)([10]), 11);
            discardImageLoadingConfig(config);
          },
        );
      }

      for (final hook in ['onThumbnailLoad', 'onImageLoad']) {
        for (final asynchronous in [false, true]) {
          test(
            '$hook invalid nested callbacks released; async=$asynchronous',
            () async {
              setHook(hook, '''${asynchronous ? 'async ' : ''}() => [
            {nested: [ComicSource.sources.image_config_test.callback]},
            ComicSource.sources.image_config_test.callback,
            {other: () => 42}
          ]''');
              // Repeated calls wrap the same JS function again. All per-result
              // wrappers must be released, not merely one JS function identity.
              for (var invocation = 0; invocation < 3; invocation++) {
                await expectLater(
                  Future.sync(
                    () => hook == 'onThumbnailLoad'
                        ? parser.parseThumbnailLoadingConfigFunc()!('image')
                        : parser.parseImageLoadingConfigFunc()!(
                            'image',
                            'id',
                            'ep',
                          ),
                  ),
                  throwsA('function $hook return invalid data'),
                );
              }
              // The shared JS function remains valid after its rejected result
              // wrappers have been released.
              expect(
                engine.runCode(
                  'ComicSource.sources.image_config_test.callback(5)',
                ),
                6,
              );
            },
          );

          test(
            '$hook thrown container releases callbacks; async=$asynchronous',
            () async {
              setHook(hook, '''${asynchronous ? 'async ' : ''}() => {
              throw {
                message: 'source callback failure',
                nested: [ComicSource.sources.image_config_test.callback]
              };
            }''');
              Object? caught;
              StackTrace? caughtStack;
              try {
                await Future.sync(
                  () => hook == 'onThumbnailLoad'
                      ? parser.parseThumbnailLoadingConfigFunc()!('image')
                      : parser.parseImageLoadingConfigFunc()!(
                          'image',
                          'id',
                          'ep',
                        ),
                );
              } catch (error, stack) {
                caught = error;
                caughtStack = stack;
              }
              expect(caught, isA<Map>());
              final failure = caught as Map;
              expect(failure['message'], 'source callback failure');
              expect(caughtStack.toString(), isNotEmpty);
              final callback =
                  (failure['nested'] as List).single as JSInvokable;
              expect(() => callback([1]), throwsA(isA<JsDisposedError>()));
            },
          );

          test('$hook preserves JS errors; async=$asynchronous', () async {
            setHook(hook, '''${asynchronous ? 'async ' : ''}() => {
              throw new Error('source image loader failed');
            }''');
            await expectLater(
              Future.sync(
                () => hook == 'onThumbnailLoad'
                    ? parser.parseThumbnailLoadingConfigFunc()!('image')
                    : parser.parseImageLoadingConfigFunc()!(
                        'image',
                        'id',
                        'ep',
                      ),
              ),
              throwsA(
                isA<JSError>().having(
                  (error) => error.message,
                  'original JS error',
                  'Error: source image loader failed',
                ),
              ),
            );
          });
        }
      }

      for (final asynchronous in [false, true]) {
        for (final valid in [false, true]) {
          test(
            'chapter results release all native fields; async=$asynchronous valid=$valid',
            () async {
              setHook('loadEp', '''${asynchronous ? 'async ' : ''}() => ({
              images: ${valid ? '["page"]' : '[() => "invalid"]'},
              unused: [ComicSource.sources.image_config_test.callback,
                {nested: ComicSource.sources.image_config_test.callback}]
            })''');
              final result = await parser.parseLoadComicPagesFunc()!(
                'book',
                'ep',
              );
              expect(result.error, !valid);
              if (valid) {
                expect(result.data, ['page']);
              } else {
                expect(result.failure!.cause, 'Invalid data');
              }
              expect(engine.debugOwnedReferenceCount, 0);
              expect(
                engine.runCode(
                  'ComicSource.sources.image_config_test.callback(4)',
                ),
                5,
              );
            },
          );
        }
      }

      for (final reject in [false, true]) {
        test(
          'cancelled chapter releases late native graph; reject=$reject',
          () async {
            setHook('loadEp', '''() => new Promise((resolve, reject) => {
            globalThis.deliverChapterGraph = ${reject ? 'reject' : 'resolve'};
          })''');
            final scope = RequestScope();
            Object? cause;
            final result = scope.runToCompletion(() async {
              final pages = await parser.parseLoadComicPagesFunc()!(
                'book',
                'ep',
              );
              cause = pages.failure!.cause;
              Error.throwWithStackTrace(cause!, pages.failure!.stackTrace!);
            });
            final checked = expectLater(
              result,
              reject
                  ? throwsA(
                      isA<Map>().having(
                        (value) => value['message'],
                        'source error',
                        'source graph failure',
                      ),
                    )
                  : throwsA(isA<RequestCancelled>()),
            );
            scope.cancel();
            engine.runCode('''void deliverChapterGraph({
            images: ["late"], message: "source graph failure",
            callback: ComicSource.sources.image_config_test.callback,
            extra: [{callback: ComicSource.sources.image_config_test.callback}]
          })''');
            await checked;
            expect(engine.debugOwnedReferenceCount, 0);
            if (reject) {
              final callback = (cause as Map)['callback'] as JSInvokable;
              expect(() => callback([1]), throwsA(isA<JsDisposedError>()));
            }
            scope.dispose();
          },
        );
      }

      for (final asynchronous in [false, true]) {
        test(
          'chapter thrown graph is released before returning Res; async=$asynchronous',
          () async {
            setHook('loadEp', '''${asynchronous ? 'async ' : ''}() => {
            throw {message: "original source failure",
              callback: ComicSource.sources.image_config_test.callback};
          }''');
            final result = await parser.parseLoadComicPagesFunc()!(
              'book',
              'ep',
            );
            final cause = result.failure!.cause as Map;
            expect(cause['message'], 'original source failure');
            expect(engine.debugOwnedReferenceCount, 0);
            expect(
              () => (cause['callback'] as JSInvokable)([1]),
              throwsA(isA<JsDisposedError>()),
            );
          },
        );
      }

      for (final valid in [false, true]) {
        test(
          'chapter cleanup failure retains original error and never retries; valid=$valid',
          () async {
            final releaseFailure = StateError(
              'Connection reset during release',
            );
            final reference = _FailingReference(releaseFailure);
            final setter =
                engine.runCode(
                      '(value) => { globalThis.chapterGraph = value; }',
                    )
                    as JSInvokable;
            try {
              setter([
                {
                  'images': valid ? ['page'] : 'invalid',
                  'extra': [reference, reference],
                },
              ]);
            } finally {
              setter.free();
            }
            engine.runCode('void (globalThis.chapterGraphCalls = 0)');
            setHook(
              'loadEp',
              '() => { ++chapterGraphCalls; return chapterGraph; }',
            );
            final result = await parser.parseLoadComicPagesFunc()!(
              'book',
              'ep',
            );
            final cause = result.failure!.cause as JsResourceReleaseFailure;
            if (!valid) {
              expect(cause.failures.first.error, 'Invalid data');
            }
            final cleanup =
                cause.failures.last.error as JsResourceReleaseFailure;
            expect(cleanup.failures.single.error, same(releaseFailure));
            expect(reference.releaseCalls, 1);
            expect(engine.runCode('chapterGraphCalls'), 1);
            expect(engine.debugOwnedReferenceCount, 0);
          },
        );
      }

      for (final reject in [false, true]) {
        test(
          'cancelled chapter retains late cleanup failure; reject=$reject',
          () async {
            final cleanupError = StateError('Connection reset during cleanup');
            final reference = _FailingReference(
              cleanupError,
              // The native Promise bridge releases its temporary borrowed
              // payload first; the second release belongs to this read.
              failOnRelease: 2,
            );
            final setter =
                engine.runCode(
                      '(value) => { globalThis.lateChapterGraph = value; }',
                    )
                    as JSInvokable;
            try {
              setter([
                {
                  'images': ['page'],
                  'message': 'source failure',
                  'callback': reference,
                },
              ]);
            } finally {
              setter.free();
            }
            engine.runCode('void (globalThis.lateChapterCalls = 0)');
            setHook('loadEp', '''() => {
            ++lateChapterCalls;
            return new Promise((resolve, reject) => {
              globalThis.deliverLateChapterGraph = ${reject ? 'reject' : 'resolve'};
            });
          }''');
            final scope = RequestScope();
            final result = scope.runToCompletion(() async {
              final pages = await parser.parseLoadComicPagesFunc()!(
                'book',
                'ep',
              );
              throw pages.failure!.cause!;
            });
            final checked = expectLater(
              result,
              throwsA(
                isA<JsResourceReleaseFailure>()
                    .having(
                      (failure) => failure.failures.first.error,
                      'original failure',
                      reject
                          ? isA<Map>().having(
                              (error) => error['message'],
                              'message',
                              'source failure',
                            )
                          : isA<RequestCancelled>(),
                    )
                    .having(
                      (failure) =>
                          (failure.failures.last.error
                                  as JsResourceReleaseFailure)
                              .failures
                              .single
                              .error,
                      'cleanup error',
                      same(cleanupError),
                    ),
              ),
            );
            scope.cancel();
            engine.runCode('void deliverLateChapterGraph(lateChapterGraph)');
            await checked;
            expect(reference.releaseCalls, 2);
            expect(engine.runCode('lateChapterCalls'), 1);
            expect(engine.debugOwnedReferenceCount, 0);
            scope.dispose();
          },
        );
      }

      test(
        'delayed invalid thumbnail result releases its late callbacks',
        () async {
          setHook('onThumbnailLoad', '''() => new Promise(resolve => {
        globalThis.resolveImageConfiguration = resolve;
      })''');
          final pending = parser.parseThumbnailLoadingConfigFunc()!('image');
          var completed = false;
          final checked = expectLater(
            pending,
            throwsA('function onThumbnailLoad return invalid data'),
          ).then((_) => completed = true);
          await pumpEventQueue();
          expect(completed, isFalse);
          engine.runCode('''void resolveImageConfiguration([
        {nested: [ComicSource.sources.image_config_test.callback]}
      ])''');
          await checked;
        },
      );

      test(
        'returning one JS callback twice gives independent result ownership',
        () async {
          setHook('onThumbnailLoad', '''() => ({
        onResponse: ComicSource.sources.image_config_test.callback,
        onLoadFailed: ComicSource.sources.image_config_test.callback
      })''');
          final first = await parser.parseThumbnailLoadingConfigFunc()!(
            'first',
          );
          final second = await parser.parseThumbnailLoadingConfigFunc()!(
            'second',
          );
          final firstResponse = first['onResponse'] as JSInvokable;
          final secondResponse = second['onResponse'] as JSInvokable;
          expect(identical(firstResponse, secondResponse), isFalse);
          discardImageLoadingConfig(first);
          expect(() => firstResponse([1]), throwsA(isA<JsDisposedError>()));
          expect(secondResponse([8]), 9);
          expect((second['onLoadFailed'] as JSInvokable)([9]), 10);
          discardImageLoadingConfig(second);
        },
      );

      test(
        'invalid result preserves parse and callback release failures',
        () async {
          final firstFailure = StateError('first callback release');
          final secondFailure = StateError('second callback release');
          final first = _FailingReference(firstFailure);
          final second = _FailingReference(secondFailure);
          final setter =
              engine.runCode(
                    '(value) => { globalThis.invalidImageConfiguration = value; }',
                  )
                  as JSInvokable;
          try {
            setter([
              [
                first,
                {'nested': second},
              ],
            ]);
          } finally {
            setter.free();
          }
          setHook('onThumbnailLoad', '() => invalidImageConfiguration');
          await expectLater(
            Future.sync(
              () => parser.parseThumbnailLoadingConfigFunc()!('image'),
            ),
            throwsA(
              isA<ImageLoadingConfigFailure>()
                  .having(
                    (failure) => failure.cause,
                    'parse failure',
                    'function onThumbnailLoad return invalid data',
                  )
                  .having(
                    (failure) => failure.cleanupFailure.failures.map(
                      (failure) => (failure.error as JsResourceReleaseFailure)
                          .failures
                          .single
                          .error,
                    ),
                    'all release failures',
                    [firstFailure, secondFailure],
                  ),
            ),
          );
          expect(first.releaseCalls, 1);
          expect(second.releaseCalls, 1);
        },
      );

      test(
        'native close diagnostics detect an intentionally retained wrapper',
        () {
          final retained = engine.runCode(
            'ComicSource.sources.image_config_test.callback',
          );
          expect(retained, isA<JSInvokable>());
          expect(
            engine.dispose,
            throwsA(
              isA<JsResourceReleaseFailure>().having(
                (failure) =>
                    failure.failures.map((item) => '${item.error}').join(),
                'native reference diagnostic',
                contains('reference leak:'),
              ),
            ),
          );
        },
      );

      for (final asynchronous in [false, true]) {
        test(
          'thrown cause and release failures retained; async=$asynchronous',
          () async {
            final releaseFailure = StateError('rejected callback release');
            final callback = _FailingReference(
              releaseFailure,
              failOnRelease: asynchronous ? 2 : 1,
            );
            final setter =
                engine.runCode(
                      '(value) => { globalThis.rejectedImageConfiguration = value; }',
                    )
                    as JSInvokable;
            try {
              setter([
                {'message': 'source failure', 'callback': callback},
              ]);
            } finally {
              setter.free();
            }
            setHook(
              'onThumbnailLoad',
              asynchronous
                  ? '''() => new Promise((resolve, reject) => {
                      globalThis.rejectImageConfiguration = reject;
                    })'''
                  : '() => { throw rejectedImageConfiguration; }',
            );
            final checked = expectLater(
              Future.sync(
                () => parser.parseThumbnailLoadingConfigFunc()!('image'),
              ),
              throwsA(
                isA<ImageLoadingConfigFailure>()
                    .having(
                      (failure) => (failure.cause as Map)['message'],
                      'source error message',
                      'source failure',
                    )
                    .having(
                      (failure) => (failure.cause as Map)['callback'],
                      'source error callback',
                      isA<JSRef>(),
                    )
                    .having(
                      (failure) =>
                          (failure.cleanupFailure.failures.single.error
                                  as JsResourceReleaseFailure)
                              .failures
                              .single
                              .error,
                      'release failure',
                      same(releaseFailure),
                    ),
              ),
            );
            if (asynchronous) {
              engine.runCode(
                'void rejectImageConfiguration(rejectedImageConfiguration)',
              );
            }
            await checked;
            expect(callback.releaseCalls, asynchronous ? 2 : 1);
          },
        );
      }
    },
    skip: nativeAvailable ? false : 'QuickJS native library unavailable',
  );
}

// The native bridge returns DartObject payloads unchanged, allowing a real
// source invocation to exercise cleanup faults without replacing its runtime.
class _FailingReference extends JSRef {
  _FailingReference(this.failure, {this.failOnRelease = 1});
  final Object failure;
  final int failOnRelease;
  var releaseCalls = 0;

  @override
  void free() {
    releaseCalls++;
    if (releaseCalls == failOnRelease) throw failure;
  }

  @override
  void destroy() {}
}
