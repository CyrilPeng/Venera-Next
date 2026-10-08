import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

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
  _Callback(this.action, {this.failure});
  final Object? Function(List<dynamic>) action;
  final Object? failure;
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) => action(args);
  @override
  void destroy() {
    destroys++;
    if (failure != null) throw failure!;
  }
}

class _UiHandler implements JsUiMessageHandler {
  _UiHandler(this.action);
  final Object? Function() action;
  @override
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) => action();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    App.version = 'test';
    App.isInitialized = false;
    Log.isMuted = true;
  });
  tearDown(() {
    Log.isMuted = false;
  });

  for (final asynchronous in [false, true]) {
    test(
      'consuming callback releases aliases, cycles and map keys; async=$asynchronous',
      () async {
        final engine = JsEngine.create();
        final scope = JsCallbackScope(engine: engine);
        final reference = _Reference();
        final second = _Reference();
        final graph = <Object, Object?>{
          reference: [reference, second],
          'alias': second,
        };
        graph['cycle'] = graph;
        final callback = _Callback((args) {
          expect(args, ['original']);
          return asynchronous ? Future<Object?>.value(graph) : graph;
        });
        final invoke = scope.retain(callback);
        callback.free();
        await invokeJsCallbackToCompletion(invoke, ['original']);
        expect([reference.destroys, second.destroys], [1, 1]);
        expect(engine.debugOwnedReferenceCount, 0);
        scope.dispose();
        expect(callback.destroys, 1);
        await engine.closeAndWait();
      },
    );
  }

  test(
    'rejection and every cleanup failure keep their original stacks',
    () async {
      final engine = JsEngine.create();
      final scope = JsCallbackScope(engine: engine);
      final firstError = StateError('first release'),
          secondError = StateError('second release');
      final first = _Reference(failure: firstError),
          second = _Reference(failure: secondError);
      final good = _Reference();
      final stack = StackTrace.fromString('original rejected callback');
      final callback = _Callback(
        (_) => Future<Object?>.error({
          'message': 'callback failed',
          'first': first,
          second: [first, second, good],
        }, stack),
      );
      final invoke = scope.retain(callback);
      callback.free();
      JsResourceReleaseFailure? failure;
      try {
        await invokeJsCallbackToCompletion(invoke, []);
      } on JsResourceReleaseFailure catch (error) {
        failure = error;
      }
      final diagnostic = failure!;
      expect(diagnostic.failures.first.error, isA<Map>());
      expect(diagnostic.failures.first.stack, same(stack));
      expect(
        (diagnostic.failures.first.error as Map)['message'],
        'callback failed',
      );
      expect(
        diagnostic.failures
            .skip(1)
            .map(
              (entry) => (entry.error as JsResourceReleaseFailure)
                  .failures
                  .single
                  .error,
            ),
        [firstError, secondError],
      );
      expect([first.destroys, second.destroys, good.destroys], [1, 1, 1]);
      scope.dispose();
      await expectLater(
        engine.closeAndWait(),
        throwsA(isA<JsResourceReleaseFailure>()),
      );
    },
  );

  test(
    'plain Dart callback fallback releases rejected graph without retry',
    () async {
      final reference = _Reference();
      final failure = {'reference': reference, 'alias': reference};
      final stack = StackTrace.fromString('plain callback stack');
      var calls = 0;
      Object? caught;
      StackTrace? caughtStack;
      try {
        await invokeJsCallbackToCompletion((_) {
          calls++;
          Error.throwWithStackTrace(failure, stack);
        }, []);
      } catch (error, trace) {
        caught = error;
        caughtStack = trace;
      }
      expect(caught, same(failure));
      expect(caughtStack, same(stack));
      expect(reference.destroys, 1);
      expect(calls, 1);
    },
  );

  test(
    'scope disposal during invocation keeps the function until its call returns',
    () async {
      final engine = JsEngine.create();
      final scope = JsCallbackScope(engine: engine);
      final pending = Completer<Object?>();
      final releaseError = StateError('invocation lease release');
      late _Callback callback;
      callback = _Callback((_) {
        scope.dispose();
        expect(callback.destroys, 0);
        return pending.future;
      }, failure: releaseError);
      final invoke = scope.retain(callback);
      callback.free();
      var settled = false;
      final result = invokeJsCallbackToCompletion(invoke, []);
      final checked = expectLater(
        result,
        throwsA(
          isA<JsResourceReleaseFailure>().having(
            (error) => error.failures.single.error,
            'lease error',
            same(releaseError),
          ),
        ),
      ).then((_) => settled = true);
      await pumpEventQueue();
      expect(settled, isFalse);
      expect(callback.destroys, 1);
      final reference = _Reference();
      pending.complete(reference);
      await checked;
      expect(reference.destroys, 1);
      await expectLater(
        engine.closeAndWait(),
        throwsA(isA<JsResourceReleaseFailure>()),
      );
    },
  );

  test(
    'engine without native runtime joins actual Dart work after closing',
    () async {
      final engine = JsEngine.create();
      final scope = JsCallbackScope(engine: engine);
      final pending = Completer<Object?>();
      final callback = _Callback((_) => pending.future);
      final invoke = scope.retain(callback);
      callback.free();
      final result = invokeJsCallbackToCompletion(invoke, []);
      final checked = expectLater(result, throwsA(isA<JsDisposedError>()));
      var closed = false;
      final closing = engine.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      final reference = _Reference();
      pending.complete(reference);
      await Future.wait([checked, closing]);
      expect(reference.destroys, 1);
    },
  );

  group('native callback completion', () {
    late JsEngine engine;
    late JsCallbackScope scope;
    setUp(() async {
      if (Platform.isWindows) {
        final native = Directory('build/windows/x64/runner/Release').absolute;
        DynamicLibrary.open('${native.path}/flutter_windows.dll');
        DynamicLibrary.open('${native.path}/flutter_qjs_plugin.dll');
      }
      engine = JsEngine.create(loadInitScript: () async => Uint8List(0));
      await engine.init();
      scope = JsCallbackScope(engine: engine);
    });
    tearDown(() async {
      scope.dispose();
      await engine.closeAndWait();
      expect(engine.debugOwnedReferenceCount, 0);
    });

    JsCallback retain(
      String code, {
      bool owned = true,
      JsCallbackScope? owner,
    }) {
      final function =
          (owned ? engine.runOwnedCode(code) : engine.runCode(code))
              as JSInvokable;
      final invoke = (owner ?? scope).retain(function);
      function.free();
      return invoke;
    }

    for (final owned in [false, true]) {
      test(
        'disposed scope keeps actual invocation and independent sibling; owned=$owned',
        () async {
          final sibling = JsCallbackScope(engine: engine);
          final invoke = retain('''key => new Promise((resolve, reject) => {
          globalThis[key] = {resolve, reject};
        })''', owned: owned);
          final other = retain('() => 73', owner: sibling);
          var complete = false;
          final result = invokeJsCallbackToCompletion(invoke, [
            'finishCallback',
          ]).then((_) => complete = true);
          scope.dispose();
          await pumpEventQueue();
          expect(complete, isFalse);
          expect(other([]), 73);
          engine.runCode('void finishCallback.resolve({callback: () => 42})');
          await result;
          expect(() => invoke([], consume: (_) {}), throwsStateError);
          sibling.dispose();
        },
      );
    }

    test(
      'late rejection after scope disposal releases references and retains its cause',
      () async {
        final invoke = retain('''() => new Promise((resolve, reject) => {
        globalThis.failCallback = reject;
      })''');
        Object? cause;
        final result = invokeJsCallbackToCompletion(invoke, []).catchError((
          Object error,
        ) {
          cause = error;
        });
        scope.dispose();
        await pumpEventQueue();
        expect(cause, isNull);
        engine.runCode(
          "void failCallback({message:'original failure', callback:()=>42})",
        );
        await result;
        expect((cause as Map)['message'], 'original failure');
        expect(
          () => (cause as Map)['callback']([]),
          throwsA(isA<JsDisposedError>()),
        );
        expect(engine.debugOwnedReferenceCount, 0);
      },
    );

    test(
      'borrowed arguments keep their native identity and do not transfer ownership',
      () async {
        final argument = engine.runOwnedCode('() => 42') as JSInvokable;
        final invoke = retain('(a, b) => [a === b, a()]');
        Object? observed;
        await invoke([
          argument,
          argument,
        ], consume: (value) => observed = value);
        expect(observed, [true, 42]);
        expect(argument([]), 42);
        argument.free();
      },
    );

    test(
      'another runtime reference is rejected before the callback executes',
      () async {
        final other = JsEngine.create(loadInitScript: () async => Uint8List(0));
        await other.init();
        final argument = other.runOwnedCode('() => 73') as JSInvokable;
        engine.runCode('void (globalThis.calls = 0)');
        final invoke = retain('() => ++calls');
        await expectLater(
          invokeJsCallbackToCompletion(invoke, [argument]),
          throwsStateError,
        );
        expect(engine.runCode('calls'), 0);
        expect(argument([]), 73);
        argument.free();
        await other.closeAndWait();
      },
    );

    test(
      'native shutdown terminates an unresolved callback without closing another engine',
      () async {
        final other = JsEngine.create(loadInitScript: () async => Uint8List(0));
        await other.init();
        final invoke = retain('() => new Promise(() => {})');
        final result = invokeJsCallbackToCompletion(invoke, []);
        final checked = expectLater(result, throwsA(isA<JsDisposedError>()));
        await engine.closeAndWait();
        await checked;
        expect(other.runCode('6 * 7'), 42);
        await other.closeAndWait();
      },
    );

    test(
      'synchronous native callback shutdown waits for its active JS stack',
      () async {
        var messages = 0;
        engine.bindUiMessageHandler(
          _UiHandler(() {
            messages++;
            engine.dispose();
            return null;
          }),
        );
        final invoke = retain('''() => {
        sendMessage({method:'UI'});
        return {callback: () => 42};
      }''');
        await expectLater(
          invokeJsCallbackToCompletion(invoke, []),
          throwsA(isA<JsDisposedError>()),
        );
        await engine.closeAndWait();
        expect(messages, 1);
      },
    );

    test('completed mutation is not replayed for transient errors', () async {
      engine.runCode('void (globalThis.calls = 0)');
      final invoke = retain(
        "() => { calls++; throw 'Connection reset by peer'; }",
      );
      await expectLater(
        invokeJsCallbackToCompletion(invoke, []),
        throwsA('Connection reset by peer'),
      );
      expect(engine.runCode('calls'), 1);
    });
  });
}
