import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native Promise ownership', () {
    late JsEngine engine;
    setUp(() async {
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      App.isInitialized = false;
      App.version = 'test';
      JsEngine.cacheJsInit(Uint8List(0));
      engine = JsEngine();
      await engine.init();
    });
    tearDown(() => engine.dispose());

    test(
      'engine disposal settles evaluation and child callback waits',
      () async {
        final evaluated = engine.runCode('new Promise(() => {})') as Future;
        final scope = JsCallbackScope();
        final child = scope.fork();
        final function =
            engine.runCode('() => new Promise(() => {})') as JSInvokable;
        final invoke = child.retain(function);
        function.free();
        final called = invoke([]) as Future;
        final evaluationCheck = expectLater(
          evaluated.timeout(const Duration(seconds: 3)),
          throwsStateError,
        );
        final callbackCheck = expectLater(
          called.timeout(const Duration(seconds: 3)),
          throwsStateError,
        );
        engine.dispose();
        engine.dispose();
        await Future.wait([evaluationCheck, callbackCheck]);
        expect(() => invoke([]), throwsStateError);
        scope.dispose();
      },
    );

    test(
      'scope closure discards late results without closing sibling work',
      () async {
        final scope = JsCallbackScope();
        final sibling = JsCallbackScope();
        final function =
            engine.runCode('''
        (key) => new Promise((resolve, reject) => {
          globalThis[key] = {resolve, reject};
        })
      ''')
                as JSInvokable;
        final invoke = scope.retain(function);
        final invokeSibling = sibling.retain(function);
        function.free();
        final success = invoke(['lateSuccess']) as Future;
        final failure = invoke(['lateFailure']) as Future;
        final kept = invokeSibling(['kept']) as Future;
        final successCheck = expectLater(success, throwsStateError);
        final failureCheck = expectLater(failure, throwsStateError);
        scope.dispose();
        await Future.wait([successCheck, failureCheck]);
        engine.runCode('''
        lateSuccess.resolve(() => 42);
        lateFailure.reject(new Error('late failure'));
        kept.resolve(73);
      ''');
        expect(await kept, 73);
        await pumpEventQueue();
        expect(engine.runCode('6 * 7'), 42);
        sibling.dispose();
      },
    );

    test('settled values and errors retain normal Promise semantics', () async {
      expect(engine.runCode('42'), 42);
      final resolved = engine.runCode('Promise.resolve(73)') as Future;
      expect(await resolved, 73);
      await expectLater(
        engine.runCode('Promise.reject(new Error("original failure"))'),
        throwsA(
          predicate((error) => error.toString().contains('original failure')),
        ),
      );
      engine.dispose();
      expect(await resolved, 73);
      expect(() => engine.runCode('42'), throwsStateError);
    });
  }, skip: !Platform.isWindows);
}
