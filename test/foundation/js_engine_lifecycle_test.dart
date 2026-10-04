import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

class _RealHttpOverrides extends HttpOverrides {}

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
