import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _PendingUi implements JsUiMessageHandler {
  final result = Completer<dynamic>();
  @override
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) => result.future;
}

class _UiReceipt implements JsUiMessageHandler {
  _UiReceipt(this.label);
  final String label;
  final owners = <JsEngine>[];
  @override
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) {
    owners.add(engine);
    return label;
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.failClose = false});
  final bool failClose;
  final List<bool> closes = [];
  @override
  void close({bool force = false}) {
    closes.add(force);
    if (failClose) throw StateError('client close failed');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw UnimplementedError();
}

class _DrainAdapter extends RHttpAdapter {
  final entered = Completer<void>();
  final draining = Completer<void>();
  final release = Completer<void>();
  final closes = <bool>[];
  CancelToken? token;
  Object? closeFailure;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    token = options.cancelToken;
    entered.complete();
    return cancelFuture!.then((_) => throw token!.cancelError!);
  }

  @override
  void close({bool force = false}) {
    closes.add(force);
    if (closeFailure != null) throw closeFailure!;
  }

  @override
  Future<void> waitForIdle() {
    if (!draining.isCompleted) draining.complete();
    return release.future;
  }
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
  setUp(() {
    App.version = 'test';
    App.isInitialized = false;
    Log.isMuted = true;
  });
  tearDown(() => Log.isMuted = false);

  test('old disposal cannot clear the replacement singleton', () async {
    final old = JsEngine();
    old.dispose();
    final replacement = JsEngine();
    old.dispose();
    expect(JsEngine(), same(replacement));
    await expectLater(old.init(), throwsStateError);
    await expectLater(old.retryInit(), throwsStateError);
    expect(old.resetDio, throwsStateError);
    replacement.dispose();
  });

  group(
    'native JS resource ownership',
    () {
      test(
        'independent engines keep their original UI handler and identity',
        () async {
          final firstUi = _UiReceipt('first');
          final secondUi = _UiReceipt('second');
          final first = JsEngine.create(
            loadInitScript: () async => Uint8List(0),
            uiMessageHandler: firstUi,
          );
          final second = JsEngine.create(
            loadInitScript: () async => Uint8List(0),
            uiMessageHandler: secondUi,
          );
          addTearDown(first.closeAndWait);
          addTearDown(second.closeAndWait);
          await first.init();
          await second.init();
          first.bindUiMessageHandler(firstUi);
          expect(() => first.bindUiMessageHandler(secondUi), throwsStateError);
          const request = 'sendMessage({method:"UI", function:"showMessage"})';
          expect(first.runCode(request), 'first');
          expect(second.runCode(request), 'second');
          expect(firstUi.owners, [same(first)]);
          expect(secondUi.owners, [same(second)]);
          await first.closeAndWait();
          expect(() => first.bindUiMessageHandler(firstUi), throwsStateError);
          expect(second.runCode(request), 'second');
          expect(secondUi.owners, [same(second), same(second)]);
        },
      );

      for (final lateFailure in [false, true]) {
        test(
          'shutdown ends a pending UI bridge before its late result; failure=$lateFailure',
          () async {
            final ui = _PendingUi();
            final engine = JsEngine.create(
              uiMessageHandler: ui,
              createHttpClient: () => Dio()..httpClientAdapter = _Adapter(),
              loadInitScript: () async => Uint8List(0),
            );
            await engine.init();
            final failed = expectLater(
              Future<dynamic>.value(
                engine.runCode(
                  'sendMessage({method:"UI", function:"showInputDialog"})',
                ),
              ),
              throwsA(isA<JsDisposedError>()),
            );
            await engine.closeAndWait();
            await failed;
            expect(ui.result.isCompleted, isFalse);
            if (lateFailure) {
              ui.result.completeError(StateError('late UI failure'));
            } else {
              ui.result.complete('late input');
            }
            await pumpEventQueue();
          },
        );
      }

      testWidgets(
        'closing JS cancels its delay timers before disposing the native bridge',
        (tester) async {
          final engine = JsEngine.create(
            createHttpClient: () => Dio()..httpClientAdapter = _Adapter(),
            loadInitScript: () async => Uint8List(0),
          );
          await tester.runAsync(engine.init);
          final failed = expectLater(
            Future<dynamic>.value(
              engine.runCode('sendMessage({method:"delay", time:1000000})'),
            ),
            throwsA(isA<JsDisposedError>()),
          );
          final closing = engine.closeAndWait();
          await tester.pumpAndSettle();
          await closing;
          await failed;
        },
      );
      test(
        'final close joins retired native clients without cancelling the parent scope',
        () async {
          final adapters = <_DrainAdapter>[];
          final engine = JsEngine.create(
            createHttpClient: () {
              final adapter = _DrainAdapter();
              adapters.add(adapter);
              return Dio()..httpClientAdapter = adapter;
            },
            loadInitScript: () async => Uint8List(0),
          );
          final parent = RequestScope();
          addTearDown(parent.dispose);
          await engine.init();
          Future<dynamic> request() => parent.run(
            () => engine.runCode(
              'sendMessage({method:"http", http_method:"GET", url:"https://example.test"})',
            ),
          );
          final first = expectLater(request(), throwsA(isA<JsDisposedError>()));
          await adapters.first.entered.future;
          engine.resetDio();
          await adapters.first.draining.future;
          expect(adapters.first.token!.isCancelled, isFalse);
          final second = expectLater(
            request(),
            throwsA(isA<JsDisposedError>()),
          );
          await adapters.last.entered.future;
          var closed = false;
          final closing = engine.closeAndWait();
          final done = closing.then((_) => closed = true);
          expect(identical(closing, engine.closeAndWait()), isTrue);
          await adapters.last.draining.future;
          expect(parent.isCancelled, isFalse);
          expect(
            adapters.every((adapter) => adapter.token!.isCancelled),
            isTrue,
          );
          adapters.last.release.complete();
          await pumpEventQueue();
          expect(closed, isFalse);
          adapters.first.release.complete();
          await Future.wait([first, second, done]);
          expect(adapters.first.closes, [false, true]);
          expect(adapters.last.closes, [true]);
        },
      );

      test(
        'close after synchronous disposal preserves both close and native drain errors',
        () async {
          final closeError = StateError('client close');
          final drainError = StateError('native drain');
          final adapter = _DrainAdapter()..closeFailure = closeError;
          final engine = JsEngine.create(
            createHttpClient: () => Dio()..httpClientAdapter = adapter,
            loadInitScript: () async => Uint8List(0),
          );
          await engine.init();
          expect(engine.dispose, throwsA(isA<JsResourceReleaseFailure>()));
          final closing = engine.closeAndWait();
          final checked = expectLater(
            closing,
            throwsA(
              isA<JsResourceReleaseFailure>().having(
                (error) => error.failures.map((failure) => failure.error),
                'both cleanup errors',
                [closeError, drainError],
              ),
            ),
          );
          await adapter.draining.future;
          adapter.release.completeError(drainError);
          await checked;
          expect(identical(closing, engine.closeAndWait()), isTrue);
          expect(adapter.closes, [true]);
        },
      );

      test(
        'final close waits for a pending initialization to relinquish its resources',
        () async {
          final script = Completer<Uint8List>();
          final adapter = _Adapter();
          final engine = JsEngine.create(
            createHttpClient: () => Dio()..httpClientAdapter = adapter,
            loadInitScript: () => script.future,
          );
          final starting = expectLater(engine.init(), throwsStateError);
          var closed = false;
          final closing = engine.closeAndWait().then((_) => closed = true);
          await pumpEventQueue();
          expect(closed, isFalse);
          script.complete(Uint8List(0));
          await Future.wait([starting, closing]);
          expect(adapter.closes, [true]);
        },
      );

      test(
        'real RHttp cleanup outlives the disposed JS result',
        () async {
          await rhttp.Rhttp.init();
          final previousProxy = appdata.settings['proxy'];
          appdata.settings['proxy'] = 'direct';
          final cancelling = Completer<void>();
          final released = Completer<void>();
          final upload = StreamController<Uint8List>(
            onCancel: () {
              cancelling.complete();
              return released.future;
            },
          );
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final received = Completer<void>();
          final sockets = <Socket>[];
          server.listen((socket) {
            sockets.add(socket);
            socket.listen((_) {
              if (!received.isCompleted) received.complete();
            }, onError: (Object _) {});
          });
          final engine = JsEngine.create(
            createHttpClient: () {
              final dio = Dio()..httpClientAdapter = RHttpAdapter();
              dio.interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) {
                    options.data = upload.stream;
                    handler.next(options);
                  },
                ),
              );
              return dio;
            },
            loadInitScript: () async => Uint8List(0),
          );
          addTearDown(() async {
            if (!released.isCompleted) released.complete();
            await engine.closeAndWait();
            unawaited(upload.close());
            for (final socket in sockets) {
              socket.destroy();
            }
            await server.close();
            appdata.settings['proxy'] = previousProxy;
          });
          await engine.init();
          final failed = expectLater(
            Future<dynamic>.value(
              engine.runCode(
                'sendMessage({method:"http", http_method:"GET", url:"http://127.0.0.1:${server.port}/"})',
              ),
            ),
            throwsA(isA<JsDisposedError>()),
          );
          await received.future.timeout(const Duration(seconds: 10));
          var closed = false;
          final closing = engine.closeAndWait().then((_) => closed = true);
          await failed;
          await cancelling.future.timeout(const Duration(seconds: 10));
          await pumpEventQueue();
          expect(closed, isFalse);
          released.complete();
          await closing.timeout(const Duration(seconds: 10));
        },
        skip: !Platform.isWindows,
      );

      test('startup and cleanup failures are both retained', () async {
        final adapter = _Adapter(failClose: true);
        final engine = JsEngine.create(
          createHttpClient: () => Dio()..httpClientAdapter = adapter,
          loadInitScript: () async => Uint8List.fromList(
            utf8.encode('throw new Error("startup failed");'),
          ),
        );
        addTearDown(engine.dispose);
        await expectLater(
          engine.init(),
          throwsA(
            isA<JsEngineInitializationFailure>()
                .having(
                  (e) => e.cause.toString(),
                  'cause',
                  contains('startup failed'),
                )
                .having(
                  (e) => e.cleanupError,
                  'cleanup',
                  isA<JsResourceReleaseFailure>(),
                ),
          ),
        );
        expect(adapter.closes, [true]);
        engine.dispose();
        expect(adapter.closes, [true]);
      });
      test(
        'temporary dart IO request releases its keep-alive connection',
        () async {
          final previousProxy = appdata.settings['proxy'];
          appdata.settings['proxy'] = 'direct';
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final closed = Completer<void>();
          final sockets = <Socket>[];
          server.listen((socket) {
            sockets.add(socket);
            var received = '';
            var replied = false;
            socket.listen(
              (bytes) {
                received += utf8.decode(bytes);
                if (!replied && received.contains('\r\n\r\n')) {
                  replied = true;
                  socket.write(
                    'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK',
                  );
                }
              },
              onDone: () {
                if (!closed.isCompleted) closed.complete();
              },
            );
          });
          final engine = JsEngine.create(
            createHttpClient: () => Dio()..httpClientAdapter = _Adapter(),
            loadInitScript: () async => Uint8List(0),
          );
          try {
            await engine.init();
            final response = await HttpOverrides.runWithHttpOverrides(
              () async => await engine.runCode(
                'sendMessage(${jsonEncode({
                  'method': 'http',
                  'http_method': 'GET',
                  'url': 'http://127.0.0.1:${server.port}/',
                  'headers': {'http_client': 'dart:io'},
                })})',
              ),
              _RealHttpOverrides(),
            );
            expect(response['status'], 200);
            expect(response['body'], 'OK');
            await closed.future.timeout(const Duration(seconds: 5));
          } finally {
            engine.dispose();
            for (final socket in sockets) {
              socket.destroy();
            }
            await server.close();
            appdata.settings['proxy'] = previousProxy;
          }
        },
      );

      test(
        'failed initialization closes client and explicit retry owns a new one',
        () async {
          final adapters = <_Adapter>[];
          var loads = 0;
          final engine = JsEngine.create(
            createHttpClient: () {
              final adapter = _Adapter();
              adapters.add(adapter);
              return Dio()..httpClientAdapter = adapter;
            },
            loadInitScript: () async => Uint8List.fromList(
              utf8.encode(
                loads++ == 0
                    ? 'throw new Error("injected init failure")'
                    : 'globalThis.ready = 42;',
              ),
            ),
          );
          addTearDown(engine.dispose);
          await expectLater(engine.init(), throwsA(anything));
          expect(adapters.single.closes, [true]);
          await engine.retryInit();
          expect(adapters, hasLength(2));
          expect(engine.runCode('ready'), 42);
          engine.dispose();
          engine.dispose();
          expect(adapters.first.closes, [true]);
          expect(adapters.last.closes, [true]);
        },
      );

      test(
        'disposal during script loading prevents late initialization',
        () async {
          final loading = Completer<Uint8List>();
          final adapter = _Adapter();
          final engine = JsEngine.create(
            createHttpClient: () => Dio()..httpClientAdapter = adapter,
            loadInitScript: () => loading.future,
          );
          final pending = engine.init();
          final failure = expectLater(pending, throwsStateError);
          engine.dispose();
          expect(adapter.closes, [true]);
          final replacement = JsEngine();
          loading.complete(
            Uint8List.fromList(utf8.encode('globalThis.late = true')),
          );
          await failure;
          expect(adapter.closes, [true]);
          expect(JsEngine(), same(replacement));
          expect(() => engine.runCode('1'), throwsStateError);
          replacement.dispose();
        },
      );

      test(
        'network reset closes previous client gracefully and disposal forces current',
        () async {
          final adapters = <_Adapter>[];
          final engine = JsEngine.create(
            createHttpClient: () {
              final adapter = _Adapter();
              adapters.add(adapter);
              return Dio()..httpClientAdapter = adapter;
            },
            loadInitScript: () async => Uint8List(0),
          );
          addTearDown(engine.dispose);
          await engine.init();
          engine.resetDio();
          expect(adapters.first.closes, [false]);
          expect(adapters.last.closes, isEmpty);
          expect(engine.runCode('6 * 7'), 42);
          engine.dispose();
          expect(adapters.last.closes, [true]);
        },
      );
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
