import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_images_parser.dart';
import 'package:venera_next/features/comic_source/source_parser_context.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/quickjs_test_environment.dart';

class _Adapter implements HttpClientAdapter {
  final started = Completer<RequestOptions>();
  final response = Completer<ResponseBody>();
  RequestScope? scope;
  Future<void>? cancelled;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    scope = RequestScope.current;
    cancelled = cancelFuture;
    started.complete(options);
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeAvailable = quickJsTestAvailable();

  group(
    'native read completion',
    () {
      late JsEngine engine;
      late _Adapter adapter;
      setUp(() async {
        App.version = 'test';
        App.isInitialized = false;
        Log.isMuted = true;
        adapter = _Adapter();
        engine = JsEngine.create(
          createHttpClient: () => Dio()..httpClientAdapter = adapter,
          loadInitScript: () async => Uint8List(0),
        );
        await engine.init();
      });
      tearDown(() {
        expect(engine.debugOwnedReferenceCount, 0);
        engine.dispose();
        Log.isMuted = false;
      });

      test(
        'consumer borrows owned graph and throwing it releases aliases once',
        () async {
          Object? borrowed;
          final result = engine.runReadCodeToCompletion<void>(
            '({callback: () => 42})',
            consume: (raw) {
              borrowed = raw;
              expect(engine.debugOwnedReferenceCount, 1);
              expect((raw['callback'] as JSInvokable)([]), 42);
              throw raw as Object;
            },
          );
          Object? caught;
          try {
            await result;
          } catch (error) {
            caught = error;
          }
          expect(caught, same(borrowed));
          expect(engine.debugOwnedReferenceCount, 0);
          expect(
            () => ((caught as Map)['callback'] as JSInvokable)([]),
            throwsA(isA<JsDisposedError>()),
          );
        },
      );

      test('cancelled read waits for actual JS resolution', () async {
        final scope = RequestScope();
        var settled = false;
        final result = scope.runToCompletion(
          () => engine.runReadCodeToCompletion('''
        new Promise(resolve => { globalThis.completeRead = resolve; })
      ''', consume: (_) => fail('cancelled read consumed a result')),
        );
        final checked = expectLater(
          result,
          throwsA(isA<RequestCancelled>()),
        ).then((_) => settled = true);
        scope.cancel();
        await pumpEventQueue();
        expect(settled, false);
        engine.runCode('void completeRead(["late-page"])');
        await checked;
        scope.dispose();
      });

      test(
        'cancelled rejection remains the source error without retry',
        () async {
          final scope = RequestScope();
          engine.runCode('void (globalThis.readAttempts = 0)');
          var settled = false;
          final result = scope.runToCompletion(
            () => engine.runReadCodeToCompletion('''
        (++readAttempts, new Promise((resolve, reject) => {
          globalThis.failRead = reject;
        }))
      ''', consume: (_) => fail('failed read consumed a result')),
          );
          final checked = expectLater(
            result,
            throwsA('Connection reset by peer'),
          ).then((_) => settled = true);
          scope.cancel();
          await pumpEventQueue();
          expect(settled, false);
          engine.runCode('void failRead("Connection reset by peer")');
          await checked;
          expect(engine.runCode('readAttempts'), 1);
          scope.dispose();
        },
      );

      test(
        'legacy read still releases its caller promptly on cancellation',
        () async {
          final scope = RequestScope();
          final result = scope.run(
            () => engine.runReadCode('''
        new Promise(resolve => { globalThis.completeRead = resolve; })
      '''),
          );
          final checked = expectLater(result, throwsA(isA<RequestCancelled>()));
          scope.cancel();
          await checked;
          engine.runCode('void completeRead(["retired-page"])');
          await pumpEventQueue();
          scope.dispose();
        },
      );

      test(
        'chapter JS propagates its request scope and Dio cancellation token',
        () async {
          final scope = RequestScope();
          final result = scope.runToCompletion(
            () => engine.runReadCodeToCompletion('''
        (async () => {
          await sendMessage({
            method: "http", http_method: "GET", url: "https://example.invalid/chapter"
          });
          return new Promise(resolve => { globalThis.completeHttpRead = resolve; });
        })()
      ''', consume: (_) => fail('cancelled HTTP read consumed a result')),
          );
          var settled = false;
          final checked = expectLater(
            result,
            throwsA(isA<RequestCancelled>()),
          ).then((_) => settled = true);
          final options = await adapter.started.future;
          expect(adapter.scope, same(scope));
          expect(options.cancelToken, isNot(same(scope.cancelToken)));
          expect(options.cancelToken!.isCancelled, isFalse);
          expect(adapter.cancelled, isNotNull);
          scope.cancel();
          expect(options.cancelToken!.isCancelled, isTrue);
          await adapter.cancelled;
          adapter.response.complete(ResponseBody.fromString('late', 200));
          await pumpEventQueue();
          expect(settled, false);
          expect(engine.runCode('typeof completeHttpRead'), 'function');
          engine.runCode('void completeHttpRead(["late HTTP page"])');
          await checked;
          scope.dispose();
        },
      );

      for (final bytes in [false, true]) {
        test(
          'HTTP cancellation keeps its type after a JS request rejects; bytes=$bytes',
          () async {
            final scope = RequestScope();
            final result = scope.runToCompletion(
              () => engine.runReadCodeToCompletion('''
              (async () => {
                const response = await sendMessage({
                  method: "http", http_method: "GET", bytes: $bytes,
                  url: "https://example.invalid/chapter"
                });
                if (response.error) throw response.error;
                return response.body;
              })()
              ''', consume: (_) => fail('cancelled request consumed data')),
            );
            final checked = expectLater(
              result,
              throwsA(isA<RequestCancelled>()),
            );
            await adapter.started.future;
            scope.cancel();
            await adapter.cancelled;
            adapter.response.complete(ResponseBody.fromString('late', 200));
            try {
              await checked;
            } finally {
              scope.dispose();
            }
          },
        );
      }

      test('an unrelated JS rejection is not hidden by cancellation', () async {
        final scope = RequestScope();
        final result = scope.runToCompletion(
          () => engine.runReadCodeToCompletion('''
          (async () => {
            const response = await sendMessage({
              method: "http", http_method: "GET",
              url: "https://example.invalid/chapter"
            });
            throw "source validation failed";
          })()
          ''', consume: (_) => fail('failed source consumed data')),
        );
        final checked = expectLater(
          result,
          throwsA('source validation failed'),
        );
        await adapter.started.future;
        scope.cancel();
        await adapter.cancelled;
        adapter.response.complete(ResponseBody.fromString('late', 200));
        try {
          await checked;
        } finally {
          scope.dispose();
        }
      });

      test(
        'reader exit drains a cancelled production chapter without failing',
        () async {
          await engine.runCode(await File('assets/init.js').readAsString());
          engine.runCode('''
          void (ComicSource.sources.exit_fixture = {comic: {
            loadEp: async () => {
              try {
                await Network.get("https://example.invalid/chapter");
              } catch (error) {
                await new Promise(resolve => { globalThis.finishCancelledChapter = resolve; });
                throw error;
              }
              return {images: ["page"]};
            }
          }});
        ''');
          final callbacks = JsCallbackScope(engine: engine);
          final parser = SourceImagesParser(
            SourceParserContext(
              key: 'exit_fixture',
              name: 'Exit fixture',
              callbacks: callbacks,
              identity: JsSourceIdentity(
                engine,
                engine.runCode(
                      '__sourceRuntime.identity(ComicSource.sources.exit_fixture)',
                    )
                    as String,
              ),
            ),
          );
          final work = ImageWork();
          final controller = ReaderController(
            pageCount: () => 1,
            chapterCount: () => 1,
            animationEnabled: () => false,
            viewport: () => null,
            onChanged: () {},
            onPageChanged: () {},
            onError: (error, stack) => fail('$error\n$stack'),
          );
          var progressWrites = 0;
          var notifications = 0;
          final session = ReaderSession(
            imageWork: work,
            durations: ReadingSessionTracker(onDuration: (_) async {}),
            progress: ReaderHistoryWriter(
              write: () async => progressWrites++,
              onError: (error, stack) => fail('$error\n$stack'),
            ),
            pauseAutoReading: (_) {},
            onClosed: () => notifications++,
            foreground: true,
          );
          try {
            final attempt = controller.beginContentLoad();
            final loading = controller.loadContent(
              attempt,
              imageWork: work,
              beforeLoad: () async {},
              loadImages: (scope) => scope.runToCompletion(() async {
                final result = await parser.parseLoadComicPagesFunc()!(
                  'book',
                  'one',
                );
                if (result.error) {
                  final failure = result.failure!;
                  Error.throwWithStackTrace(
                    failure.cause ?? failure,
                    failure.stackTrace!,
                  );
                }
                return result.data;
              }),
              prepareMode: () async =>
                  fail('cancelled chapter must not prepare'),
            );
            await adapter.started.future;
            session.scheduleProgress();
            var prepared = false;
            final preparing = session.prepareForExit().then((release) {
              prepared = true;
              return release;
            });
            await adapter.cancelled;
            await pumpEventQueue();
            expect(prepared, isFalse);
            expect(progressWrites, 1);
            expect(
              engine.runCode('typeof finishCancelledChapter === "function"'),
              isTrue,
            );
            adapter.response.complete(ResponseBody.fromString('late', 200));
            engine.runCode('void finishCancelledChapter()');
            final release = await preparing;
            expect(await loading, ReaderContentLoadResult.ignored);
            expect(notifications, 1);
            expect(controller.content.error, isNull);
            release();
          } finally {
            if (!adapter.response.isCompleted) {
              adapter.response.complete(
                ResponseBody.fromString('cleanup', 200),
              );
            }
            if (engine.runCode(
                  'typeof finishCancelledChapter === "function"',
                ) ==
                true) {
              engine.runCode('void finishCancelledChapter()');
            }
            callbacks.dispose();
            controller.dispose();
            await session.dispose();
          }
        },
      );

      test(
        'a retained image callback retains typed HTTP cancellation',
        () async {
          final scope = RequestScope();
          final callbacks = JsCallbackScope(engine: engine);
          final function =
              engine.runOwnedCode('''
          async () => {
            const response = await sendMessage({method: "http", http_method: "GET",
              url: "https://example.invalid/image-config"});
            if (response.error) throw response.error;
            return response.body;
          }
        ''')
                  as JSInvokable;
          final callback = callbacks.retain(function);
          final result = scope.runToCompletion(() async {
            await invokeJsCallbackToCompletion(callback, []);
          });
          final checked = expectLater(result, throwsA(isA<RequestCancelled>()));
          await adapter.started.future;
          scope.cancel();
          await adapter.cancelled;
          adapter.response.complete(ResponseBody.fromString('late', 200));
          try {
            await checked;
          } finally {
            callbacks.dispose();
            function.free();
            scope.dispose();
          }
        },
      );
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
