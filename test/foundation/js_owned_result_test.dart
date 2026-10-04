import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

class _Reference extends JSRef {
  _Reference({this.failure});
  final Object? failure;
  int destroys = 0;

  @override
  void destroy() {
    destroys++;
    if (failure != null) throw failure!;
  }
}

class _Callback extends JSInvokable {
  _Callback(this.callback, {this.failure});
  final dynamic Function(List args, dynamic thisVal) callback;
  final Object? failure;
  int destroys = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) => callback(args, thisVal);

  @override
  void destroy() {
    destroys++;
    if (failure != null) throw failure!;
  }
}

bool _nativeAvailable() {
  try {
    if (Platform.isWindows) {
      final directory = Directory('build/windows/x64/runner/Release').absolute;
      DynamicLibrary.open('${directory.path}/flutter_windows.dll');
      DynamicLibrary.open('${directory.path}/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<JsEngine> _nativeEngine() async {
  final engine = JsEngine.create(loadInitScript: () async => Uint8List(0));
  addTearDown(engine.dispose);
  await engine.init();
  return engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    App.isInitialized = false;
    App.version = 'test';
    Log.isMuted = true;
  });
  tearDown(() => Log.isMuted = false);

  group('owned result graph', () {
    test('invocation unwrap preserves receiver aliases and typed data', () {
      final engine = JsEngine.create();
      addTearDown(engine.dispose);
      final argument = _Callback((_, _) => 3);
      final wrappedArgument = engine.debugOwnResult(argument) as JSInvokable;
      final bytes = Uint8List.fromList([1, 2, 3]);
      final numbers = <int>[4, 5];
      final byteData = ByteData(4);
      final payload = <String, dynamic>{
        'callback': wrappedArgument,
        'alias': wrappedArgument,
        'bytes': bytes,
        'byteData': byteData,
        'numbers': numbers,
      };
      payload['cycle'] = payload;
      final receiver = _Callback((args, thisVal) {
        final unwrapped = args.single as Map;
        expect(unwrapped, same(thisVal));
        expect(unwrapped['cycle'], same(unwrapped));
        expect(unwrapped['callback'], same(argument));
        expect(unwrapped['alias'], same(argument));
        expect(unwrapped['bytes'], same(bytes));
        expect(unwrapped['byteData'], same(byteData));
        expect(unwrapped['numbers'], same(numbers));
        return 7;
      });
      final wrappedReceiver = engine.debugOwnResult(receiver) as JSInvokable;
      expect(wrappedReceiver.invoke([payload], payload), 7);
      expect(payload['callback'], same(wrappedArgument));
      expect(payload['cycle'], same(payload));
      expect(engine.debugOwnedReferenceCount, 2);
      wrappedReceiver.free();
      wrappedArgument.free();
      expect(receiver.destroys, 1);
      expect(argument.destroys, 1);
    });

    test('aliases and cycles adopt each reference once and preserve bytes', () {
      final engine = JsEngine.create();
      final callback = _Callback((args, _) => args.single);
      final reference = _Reference();
      final bytes = Uint8List.fromList([1, 2, 3]);
      final graph = <String, dynamic>{};
      final list = <dynamic>[callback, reference, graph];
      graph.addAll({
        'first': callback,
        'alias': callback,
        'nested': list,
        'reference': reference,
        'self': graph,
        'bytes': bytes,
      });
      final owned = engine.debugOwnResult(graph) as Map;
      expect(owned['first'], same(owned['alias']));
      expect(owned['first'], same((owned['nested'] as List).first));
      expect(owned['self'], same(owned));
      expect((owned['nested'] as List).last, same(owned));
      expect(owned['reference'], same((owned['nested'] as List)[1]));
      expect(owned['bytes'], same(bytes));
      expect((owned['first'] as JSInvokable)([42]), 42);
      expect(engine.debugOwnedReferenceCount, 2);
      (owned['first'] as JSRef).free();
      (owned['alias'] as JSRef).free();
      expect(callback.destroys, 1);
      expect(engine.debugOwnedReferenceCount, 1);
      engine.dispose();
      expect(reference.destroys, 1);
      (owned['reference'] as JSRef).free();
      expect(reference.destroys, 1);
      expect(engine.debugOwnedReferenceCount, 0);
    });

    test('released raw references cannot be adopted into a new wrapper', () {
      final engine = JsEngine.create();
      final raw = _Callback((_, _) => 1);
      final owned = engine.debugOwnResult(raw) as JSInvokable;
      owned.free();
      expect(() => engine.debugOwnResult(raw), throwsA(isA<JsDisposedError>()));
      expect(() => owned([]), throwsA(isA<JsDisposedError>()));
      expect(owned.dup, throwsA(isA<JsDisposedError>()));
      engine.dispose();
      expect(raw.destroys, 1);
    });

    test(
      'runtime close forcibly releases native ownership despite caller dup',
      () {
        final engine = JsEngine.create();
        final raw = _Callback((_, _) => 1);
        final owned = engine.debugOwnResult(raw) as JSInvokable;
        owned.dup();
        owned.dup();
        engine.dispose();
        expect(raw.destroys, 1);
        owned.free();
        owned.free();
        owned.free();
        owned.destroy();
        expect(raw.destroys, 1);
        expect(() => owned([]), throwsA(isA<JsDisposedError>()));
      },
    );

    test(
      'destroy settles its pending calls and releases late result aliases',
      () async {
        final engine = JsEngine.create();
        final result = Completer<dynamic>();
        final raw = _Callback((_, _) => result.future);
        final owned = engine.debugOwnResult(raw) as JSInvokable;
        final pending = owned([]) as Future;
        final observed = expectLater(pending, throwsA(isA<JsDisposedError>()));
        owned.free();
        await observed;
        final lateReference = _Reference();
        result.complete({'callback': lateReference, 'alias': lateReference});
        await Future<void>.delayed(Duration.zero);
        expect(lateReference.destroys, 1);
        expect(raw.destroys, 1);
        expect(engine.debugOwnedReferenceCount, 0);
        engine.dispose();
      },
    );

    test(
      'all native release failures survive and cannot prevent other releases',
      () async {
        final engine = JsEngine.create();
        final firstFailure = StateError('first native release failed');
        final secondFailure = StateError('second native release failed');
        final pending = Completer<dynamic>();
        final first = _Callback(
          (_, _) => pending.future,
          failure: firstFailure,
        );
        final second = _Reference(failure: secondFailure);
        final third = _Reference();
        final owned = engine.debugOwnResult([first, second, third]) as List;
        final observed = expectLater(
          (owned.first as JSInvokable)([]) as Future,
          throwsA(isA<JsDisposedError>()),
        );
        expect(
          engine.dispose,
          throwsA(
            isA<JsResourceReleaseFailure>().having(
              (failure) => failure.failures.map(
                (entry) => (entry.error as JsResourceReleaseFailure)
                    .failures
                    .single
                    .error,
              ),
              'every failing native release',
              [same(firstFailure), same(secondFailure)],
            ),
          ),
        );
        await observed;
        expect(first.destroys, 1);
        expect(second.destroys, 1);
        expect(third.destroys, 1);
        expect(engine.debugOwnedReferenceCount, 0);
        for (final reference in owned.cast<JSRef>()) {
          reference.free();
        }
        engine.dispose();
        expect(first.destroys, 1);
        expect(second.destroys, 1);
      },
    );

    test(
      'a late rejected graph is released once after callback destruction',
      () async {
        final engine = JsEngine.create();
        final result = Completer<dynamic>();
        final raw = _Callback((_, _) => result.future);
        final owned = engine.debugOwnResult(raw) as JSInvokable;
        final observed = expectLater(
          owned([]) as Future,
          throwsA(isA<JsDisposedError>()),
        );
        owned.free();
        await observed;
        final rejectedReference = _Reference();
        result.completeError([rejectedReference, rejectedReference]);
        await Future<void>.delayed(Duration.zero);
        expect(rejectedReference.destroys, 1);
        expect(raw.destroys, 1);
        engine.dispose();
      },
    );

    test(
      'late cleanup errors are reported together without unhandled errors',
      () async {
        final engine = JsEngine.create();
        final result = Completer<dynamic>();
        final raw = _Callback((_, _) => result.future);
        final owned = engine.debugOwnResult(raw) as JSInvokable;
        final observed = expectLater(
          owned([]) as Future,
          throwsA(isA<JsDisposedError>()),
        );
        owned.free();
        await observed;
        final first = _Reference(failure: StateError('first cleanup'));
        final second = _Reference(failure: StateError('second cleanup'));
        final errors = <Object>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) {
          errors.add(details.exception);
          throw StateError('diagnostic handler also failed');
        };
        try {
          result.complete([first, first, second]);
          await Future<void>.delayed(Duration.zero);
          expect(first.destroys, 1);
          expect(second.destroys, 1);
          expect(errors, hasLength(1));
          expect(
            (errors.single as JsResourceReleaseFailure).failures,
            hasLength(2),
          );
        } finally {
          FlutterError.onError = previous;
          engine.dispose();
        }
      },
    );

    test(
      'returned and rejected callback graphs retain their original owner',
      () async {
        final engine = JsEngine.create();
        final nested = _Callback((_, _) => 42);
        final rejected = _Callback((_, _) => throw {'nested': nested});
        final owned = engine.debugOwnResult(rejected) as JSInvokable;
        Object? caught;
        try {
          owned([]);
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<Map>());
        expect(((caught as Map)['nested'] as JSInvokable)([]), 42);
        expect(engine.debugOwnedReferenceCount, 2);
        engine.dispose();
        expect(nested.destroys, 1);
        expect(rejected.destroys, 1);
      },
    );
  });

  group(
    'native owned result lifecycle',
    () {
      test(
        'callback arguments and receivers retain native function identity',
        () async {
          final engine = await _nativeEngine();
          engine.runCode('globalThis.shared = () => 3; void 0;');
          final accepts =
              engine.runOwnedCode('''
          (function (payload) {
            return payload.first === shared &&
              payload.alias === shared &&
              payload.nested[0] === shared &&
              payload.self === payload &&
              this === shared;
          })
        ''')
                  as JSInvokable;
          final callback = engine.runOwnedCode('shared') as JSInvokable;
          final payload = <String, dynamic>{
            'first': callback,
            'alias': callback,
            'nested': [callback],
          };
          payload['self'] = payload;
          expect(accepts.invoke([payload], callback), isTrue);
          accepts.free();
          expect(callback([]), 3);
          callback.free();
          expect(engine.debugOwnedReferenceCount, 0);
          engine.dispose();
        },
      );

      test(
        'callback arguments do not allocate a leaking Dart callback bridge',
        () async {
          final engine = await _nativeEngine();
          final accepts =
              engine.runOwnedCode('(callback) => callback((value) => value)')
                  as JSInvokable;
          final callback =
              engine.runOwnedCode('(argument) => argument(7)') as JSInvokable;
          expect(accepts([callback]), 7);
          accepts.free();
          callback.free();
          expect(engine.debugOwnedReferenceCount, 0);
          // This previously reported a leaked raw wrapper for `(value) => value`
          // even though both public owned wrappers had been released.
          expect(engine.dispose, returnsNormally);
        },
      );

      test(
        'invocation rejects foreign arguments and receivers before entering JS',
        () async {
          final engine = await _nativeEngine();
          final foreignEngine = await _nativeEngine();
          engine.runCode('globalThis.invocations = 0; void 0;');
          final accepts =
              engine.runOwnedCode('() => { invocations++; return 7; }')
                  as JSInvokable;
          final foreign = foreignEngine.runOwnedCode('() => 3') as JSInvokable;
          final rejected = throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'runtime ownership failure',
              contains('another runtime'),
            ),
          );
          expect(
            () => accepts([
              {
                'nested': [foreign],
              },
            ]),
            rejected,
          );
          expect(() => accepts.invoke([], foreign), rejected);
          expect(engine.runCode('invocations'), 0);
          expect(foreign([]), 3);
          expect(accepts([]), 7);
          expect(engine.debugOwnedReferenceCount, 1);
          expect(foreignEngine.debugOwnedReferenceCount, 1);
          accepts.free();
          foreign.free();
        },
      );

      test(
        'invocation rejects released arguments and receivers before entering JS',
        () async {
          final engine = await _nativeEngine();
          engine.runCode('globalThis.invocations = 0; void 0;');
          final accepts =
              engine.runOwnedCode('() => { invocations++; return 7; }')
                  as JSInvokable;
          final released = engine.runOwnedCode('() => 3') as JSInvokable;
          released.free();
          expect(
            () => accepts([
              {
                'nested': [released],
              },
            ]),
            throwsA(isA<JsDisposedError>()),
          );
          expect(
            () => accepts.invoke([], released),
            throwsA(isA<JsDisposedError>()),
          );
          expect(engine.runCode('invocations'), 0);
          expect(accepts([]), 7);
          accepts.free();
          expect(engine.debugOwnedReferenceCount, 0);
        },
      );

      test(
        'argument unwrapping keeps byte buffers and nested container aliases',
        () async {
          final engine = await _nativeEngine();
          final accepts =
              engine.runOwnedCode('''
          (payload) => {
            const bytes = new Uint8Array(payload.bytes);
            return bytes[0] === 2 && bytes[1] === 4 &&
              payload.first === payload.alias &&
              payload.first[0] === payload.first;
          }
        ''')
                  as JSInvokable;
          final cycle = <dynamic>[];
          cycle.add(cycle);
          final bytes = Uint8List.fromList([2, 4]);
          expect(
            accepts([
              {'first': cycle, 'alias': cycle, 'bytes': bytes},
            ]),
            isTrue,
          );
          expect(bytes, [2, 4]);
          expect(cycle.single, same(cycle));
          accepts.free();
        },
      );

      test(
        'closing runtime settles never-ending callback Promise and late free is safe',
        () async {
          final engine = await _nativeEngine();
          final callback =
              engine.runOwnedCode('(() => new Promise(() => {}))')
                  as JSInvokable;
          final observed = expectLater(
            callback([]) as Future,
            throwsA(isA<JsDisposedError>()),
          );
          expect(engine.debugOwnedReferenceCount, 1);
          engine.dispose();
          await observed;
          expect(engine.debugOwnedReferenceCount, 0);
          callback.free();
          callback.destroy();
          expect(() => callback([]), throwsA(isA<JsDisposedError>()));
        },
      );

      test(
        'closing runtime settles a never-ending evaluation Promise',
        () async {
          final engine = await _nativeEngine();
          final observed = expectLater(
            engine.runOwnedCode('new Promise(() => {})') as Future,
            throwsA(isA<JsDisposedError>()),
          );
          engine.dispose();
          await observed;
        },
      );

      for (final asynchronous in [false, true]) {
        test(
          'nested callback results are adopted before delivery (async: $asynchronous)',
          () async {
            final engine = await _nativeEngine();
            final callback =
                engine.runOwnedCode('''
          (${asynchronous ? 'async ' : ''}() => {
            const callback = () => new Uint8Array([2, 4]).buffer;
            const value = {nested: [callback], same: callback};
            value.self = value;
            return value;
          })
        ''')
                    as JSInvokable;
            final graph = await callback([]) as Map;
            expect(graph['self'], same(graph));
            final first = (graph['nested'] as List).single as JSInvokable;
            final second = graph['same'] as JSInvokable;
            // QuickJS creates an independently duplicated wrapper at each field.
            expect(engine.debugOwnedReferenceCount, 3);
            expect(first([]), isA<Uint8List>());
            expect(first([]), [2, 4]);
            first.free();
            expect(second([]), [2, 4]);
            callback.free();
            expect(engine.debugOwnedReferenceCount, 1);
            engine.dispose();
            second.free();
          },
        );
      }

      test(
        'same JS function returned repeatedly retains independent native ownership',
        () async {
          final engine = await _nativeEngine();
          engine.runCode('globalThis.sameFunction = () => 42; void 0;');
          final first = engine.runOwnedCode('sameFunction') as JSInvokable;
          final second = engine.runOwnedCode('sameFunction') as JSInvokable;
          expect(first, isNot(same(second)));
          expect(engine.debugOwnedReferenceCount, 2);
          first.free();
          expect(second([]), 42);
          expect(() => first([]), throwsA(isA<JsDisposedError>()));
          second.free();
          expect(engine.debugOwnedReferenceCount, 0);
          final third = engine.runOwnedCode('sameFunction') as JSInvokable;
          expect(third([]), 42);
          third.dup();
          engine.dispose();
          third.free();
          third.free();
        },
      );

      for (final asynchronous in [false, true]) {
        test(
          'thrown callback containers remain owned and diagnostics do not leak (async: $asynchronous)',
          () async {
            final engine = await _nativeEngine();
            final code =
                '''
          (${asynchronous ? 'async ' : ''}() => {
            const callback = () => 7;
            throw {callbacks: [callback, callback]};
          })()
        ''';
            Object? caught;
            try {
              await engine.runOwnedCode(code);
            } catch (error) {
              caught = error;
            }
            expect(caught, isA<Map>());
            final callbacks = (caught as Map)['callbacks'] as List;
            expect((callbacks.first as JSInvokable)([]), 7);
            expect(engine.debugOwnedReferenceCount, 2);
            for (final callback in callbacks.cast<JSRef>()) {
              callback.free();
            }
            expect(engine.debugOwnedReferenceCount, 0);
            engine.dispose();
          },
        );
      }

      test(
        'Promise rejection from an owned callback recursively owns its error',
        () async {
          final engine = await _nativeEngine();
          final callback =
              engine.runOwnedCode('''
        (async () => { throw [() => 9]; })
      ''')
                  as JSInvokable;
          Object? caught;
          try {
            await callback([]);
          } catch (error) {
            caught = error;
          }
          expect(caught, isA<List>());
          final errorCallback = (caught as List).single as JSInvokable;
          expect(errorCallback([]), 9);
          expect(engine.debugOwnedReferenceCount, 2);
          engine.dispose();
          callback.free();
          errorCallback.free();
        },
      );

      test(
        'old wrappers cannot use or release a replacement runtime',
        () async {
          final old = await _nativeEngine();
          final callback = old.runOwnedCode('(() => 1)') as JSInvokable;
          old.dispose();
          final replacement = await _nativeEngine();
          final current = replacement.runOwnedCode('(() => 2)') as JSInvokable;
          expect(() => callback([]), throwsA(isA<JsDisposedError>()));
          callback.free();
          callback.destroy();
          old.dispose();
          expect(replacement.debugOwnedReferenceCount, 1);
          expect(current([]), 2);
          expect(
            () => replacement.debugOwnResult(callback),
            throwsA(isA<StateError>()),
          );
          replacement.dispose();
          current.free();
        },
      );

      test(
        'host Promise rejection keeps its diagnostic while freeing diagnostic refs',
        () async {
          final engine = await _nativeEngine();
          Log.isMuted = false;
          final previousLogs = Log.logs.length;
          Object? caught;
          try {
            await engine.runOwnedCode('''
          (async () => {
            throw {kind: 'owned rejection diagnostic', callback: () => 42};
          })()
        ''');
          } catch (error) {
            caught = error;
          }
          expect(
            Log.logs.skip(previousLogs).map((entry) => entry.content),
            contains(
              allOf(
                contains('Unhandled promise rejection:'),
                contains('owned rejection diagnostic'),
              ),
            ),
          );
          ((caught as Map)['callback'] as JSRef).free();
          expect(engine.debugOwnedReferenceCount, 0);
          engine.dispose();
        },
      );
    },
    skip: _nativeAvailable() ? false : 'QuickJS native library unavailable',
  );
}
