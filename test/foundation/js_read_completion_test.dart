import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

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
          expect(options.cancelToken, same(scope.cancelToken));
          expect(adapter.cancelled, isNotNull);
          scope.cancel();
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
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
