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
  _Callback(this.action);
  final Object? Function() action;
  int calls = 0;
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return action();
  }

  @override
  void destroy() => destroys++;
}

class _UiHandler implements JsUiMessageHandler {
  _UiHandler(this.action);
  final void Function() action;
  @override
  Object? handleUIMessage(
    Map<String, dynamic> message, {
    required JsEngine engine,
  }) {
    action();
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    App.version = 'test';
    App.isInitialized = false;
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });

  for (final reject in [false, true]) {
    test(
      'immediate callback borrows the original graph before release; reject=$reject',
      () async {
        final engine = JsEngine.create();
        final scope = JsCallbackScope(engine: engine);
        final reference = _Reference();
        final graph = <Object, Object?>{
          reference: [reference],
          'message': 'original graph',
        };
        graph['cycle'] = graph;
        final stack = StackTrace.fromString('immediate original callback');
        final callback = _Callback(() {
          if (reject) Error.throwWithStackTrace(graph, stack);
          return graph;
        });
        final invoke = scope.retainImmediate(callback);
        callback.free();
        var observed = false;
        final completion = invoke([], (value, failureStack) {
          observed = true;
          expect(value, same(graph));
          expect(failureStack, reject ? same(stack) : isNull);
          expect(reference.destroys, 0);
        });
        expect(observed, isTrue);
        if (reject) {
          await expectLater(completion, throwsA(isA<Map>()));
        } else {
          await completion;
        }
        expect(reference.destroys, 1);
        expect(callback.calls, 1);
        expect(engine.debugOwnedReferenceCount, 0);
        scope.dispose();
        await engine.closeAndWait();
      },
    );
  }

  test('immediate Promise marker never lends its native result', () async {
    final engine = JsEngine.create();
    final scope = JsCallbackScope(engine: engine);
    final pending = Completer<Object?>();
    final callback = _Callback(() => pending.future);
    final invoke = scope.retainImmediate(callback);
    callback.free();
    late Future<dynamic> marker;
    final completion = invoke([], (value, stack) {
      expect(stack, isNull);
      marker = value as Future<dynamic>;
      expect(marker.toString(), Completer<dynamic>().future.toString());
    });
    var completed = false;
    final observed = completion.then<void>((_) => completed = true);
    scope.dispose();
    await pumpEventQueue();
    expect(completed, isFalse);
    final reference = _Reference();
    pending.complete({'ref': reference});
    await observed;
    expect(await marker, isNull);
    expect(reference.destroys, 1);
    expect(callback.calls, 1);
    await engine.closeAndWait();
  });

  test('throwing the borrowed result releases shared wrappers once', () async {
    final engine = JsEngine.create();
    final scope = JsCallbackScope(engine: engine);
    final reference = _Reference();
    final graph = {'ref': reference, 'alias': reference};
    final stack = StackTrace.fromString('immediate conversion failed');
    final callback = _Callback(() => graph);
    final invoke = scope.retainImmediate(callback);
    callback.free();
    Object? caught;
    StackTrace? caughtStack;
    try {
      await invoke([], (value, _) => Error.throwWithStackTrace(value, stack));
    } catch (error, trace) {
      caught = error;
      caughtStack = trace;
    }
    expect(caught, isA<Map>());
    expect(caughtStack, same(stack));
    expect(reference.destroys, 1);
    expect(engine.debugOwnedReferenceCount, 0);
    scope.dispose();
    await engine.closeAndWait();
  });

  test(
    'original rejection, conversion and release failures retain their stacks',
    () async {
      final engine = JsEngine.create();
      final scope = JsCallbackScope(engine: engine);
      final releaseError = StateError('original release');
      final reference = _Reference(failure: releaseError);
      final graph = {'ref': reference, 'message': 'original rejection'};
      final callbackStack = StackTrace.fromString('callback origin');
      final consumerStack = StackTrace.fromString('consumer origin');
      final consumerError = StateError('conversion');
      final callback = _Callback(
        () => Error.throwWithStackTrace(graph, callbackStack),
      );
      final invoke = scope.retainImmediate(callback);
      callback.free();
      JsResourceReleaseFailure? failure;
      try {
        await invoke(
          [],
          (_, _) => Error.throwWithStackTrace(consumerError, consumerStack),
        );
      } on JsResourceReleaseFailure catch (error) {
        failure = error;
      }
      expect(failure!.failures, hasLength(3));
      expect(
        (failure.failures[0].error as Map)['message'],
        'original rejection',
      );
      expect(failure.failures[0].stack, same(callbackStack));
      expect(failure.failures[1].error, same(consumerError));
      expect(failure.failures[1].stack, same(consumerStack));
      expect(
        (failure.failures[2].error as JsResourceReleaseFailure)
            .failures
            .single
            .error,
        same(releaseError),
      );
      expect(reference.destroys, 1);
      scope.dispose();
      await expectLater(
        engine.closeAndWait(),
        throwsA(isA<JsResourceReleaseFailure>()),
      );
    },
  );

  test('immediate consumer failure still joins a pending invocation', () async {
    final engine = JsEngine.create();
    final scope = JsCallbackScope(engine: engine);
    final pending = Completer<Object?>();
    final callback = _Callback(() => pending.future);
    final invoke = scope.retainImmediate(callback);
    callback.free();
    final cause = StateError('immediate consumer');
    var settled = false;
    final completion = invoke([], (_, _) => throw cause);
    final checked = expectLater(
      completion,
      throwsA(same(cause)),
    ).then<void>((_) => settled = true);
    scope.dispose();
    await pumpEventQueue();
    expect(settled, isFalse);
    final reference = _Reference();
    pending.complete({
      reference: [reference],
    });
    await checked;
    expect(reference.destroys, 1);
    expect(callback.calls, 1);
    await engine.closeAndWait();
  });

  for (final closeInConsumer in [false, true]) {
    test(
      'native immediate invocation protects reentrant shutdown; consumer=$closeInConsumer',
      () async {
        if (Platform.isWindows) {
          final native = Directory('build/windows/x64/runner/Release').absolute;
          DynamicLibrary.open('${native.path}/flutter_windows.dll');
          DynamicLibrary.open('${native.path}/flutter_qjs_plugin.dll');
        }
        late JsEngine engine;
        Future<void>? closing;
        engine = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
          uiMessageHandler: _UiHandler(() {
            closing = engine.closeAndWait();
          }),
        );
        await engine.init();
        final scope = JsCallbackScope(engine: engine);
        final raw =
            engine.runOwnedCode('''
        () => {
          ${closeInConsumer ? '' : 'sendMessage({method:"UI", function:"close"});'}
          return { fn: () => { sendMessage({method:"UI", function:"close"}); return 42; } };
        }
      ''')
                as JSInvokable;
        final invoke = scope.retainImmediate(raw);
        raw.free();
        var observations = 0;
        final completion = invoke([], (value, stack) {
          observations++;
          if (closeInConsumer) {
            expect(stack, isNull);
            expect(((value as Map)['fn'] as JSInvokable)([]), 42);
          } else {
            expect(value, isA<JsDisposedError>());
            expect(stack, isNotNull);
          }
        });
        await expectLater(completion, throwsA(isA<JsDisposedError>()));
        expect(closing, isNotNull);
        await closing;
        expect(observations, 1);
        expect(engine.debugOwnedReferenceCount, 0);
        scope.dispose();
      },
    );
  }
}
