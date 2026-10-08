import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/debug_evaluator.dart';
import 'package:venera_next/features/settings/debug_evaluator_runtime.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/operation_failure.dart';

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

  group('native debug evaluator ownership', () {
    late JsEngine engine;
    setUp(() async {
      engine = JsEngine.create(loadInitScript: () async => Uint8List(0));
      await engine.init();
    });
    tearDown(() async {
      final remaining = engine.debugOwnedReferenceCount;
      await engine.closeAndWait();
      expect(remaining, 0);
    });

    test(
      'multi-level descendants release success and rejected graphs',
      () async {
        final task = createDebugEvaluator(engine).start('''
        ({first: Promise.resolve({
          callback: () => 1,
          child: Promise.reject({rejected: () => 2})
        }), second: Promise.resolve({other: () => 3})})
      ''');
        expect(await task.result, contains('first:'));
        await expectLater(
          task.completion,
          throwsA(
            isA<DebugEvaluationFailure>().having(
              (e) =>
                  (e.cleanupFailures.single.error as JsResourceReleaseFailure)
                      .failures
                      .single
                      .error,
              'original nested rejection',
              isA<Map>().having(
                (e) => e.containsKey('rejected'),
                'rejected graph',
                isTrue,
              ),
            ),
          ),
        );
        expect(engine.debugOwnedReferenceCount, 0);
      },
    );

    test(
      'closing nested work cancels completion while sibling stays active',
      () async {
        final sibling = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
        );
        await sibling.init();
        addTearDown(sibling.closeAndWait);
        final task = createDebugEvaluator(
          engine,
        ).start('({pending: new Promise(() => {}), callback: () => 42})');
        final displayed = await task.result;
        expect(displayed, contains('pending:'));
        final checked = expectLater(
          task.completion,
          throwsA(
            isA<DebugEvaluationFailure>().having(
              (e) => e.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        await engine.closeAndWait();
        await checked;
        expect(await task.result, displayed);
        expect(
          await createDebugEvaluator(sibling).start('6 * 7').completion,
          '42',
        );
      },
    );

    test('nested Promise references release before runtime closure', () async {
      final task = createDebugEvaluator(
        engine,
      ).start('({pending: Promise.resolve({callback: () => 42})})');
      expect(await task.result, contains('pending:'));
      await task.completion;
      await pumpEventQueue();
      expect(engine.debugOwnedReferenceCount, 0);
    });

    test(
      'display is immediate while nested Promise cleanup remains pending',
      () async {
        final task = createDebugEvaluator(engine).start(
          '({pending: new Promise(resolve => { globalThis.finishNested = resolve; })})',
        );
        expect(await task.result, contains('pending:'));
        var completed = false;
        final completion = task.completion.then((_) => completed = true);
        await pumpEventQueue();
        expect(completed, isFalse);
        engine.runOwnedCode('void finishNested({callback: () => 42})');
        await completion;
        expect(engine.debugOwnedReferenceCount, 0);
      },
    );

    test(
      'success and Promise rejection release native result graphs',
      () async {
        final evaluator = createDebugEvaluator(engine);
        expect(
          await evaluator.start('({chapters: 3})').result,
          '{\n  "chapters": 3\n}',
        );
        final output = await evaluator
            .start(
              '(() => { const f = () => 42; return {first:f, nested:[f]}; })()',
            )
            .result;
        expect(output, contains('first:'));
        expect(engine.debugOwnedReferenceCount, 0);
        await expectLater(
          evaluator.start('Promise.reject({callback: () => 42})').result,
          throwsA(isA<DebugEvaluationFailure>()),
        );
        await expectLater(
          evaluator.start('throw ({callback: () => 42})').result,
          throwsA(isA<DebugEvaluationFailure>()),
        );
        expect(engine.debugOwnedReferenceCount, 0);
      },
    );

    test(
      'runtime closing between evaluation and consumption cannot double free',
      () async {
        final task = createDebugEvaluator(
          engine,
        ).start('({callback: () => 42})');
        expect(engine.debugOwnedReferenceCount, 1);
        engine.dispose();
        expect(await task.result, contains('callback:'));
        expect(await task.completion, contains('callback:'));
        expect(engine.debugOwnedReferenceCount, 0);
      },
    );

    test(
      'closing pending runtime settles with cancellation and leaves sibling active',
      () async {
        final sibling = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
        );
        await sibling.init();
        addTearDown(sibling.closeAndWait);
        final evaluator = createDebugEvaluator(engine);
        final task = evaluator.start('new Promise(() => {})');
        final checked = expectLater(
          task.result,
          throwsA(
            isA<DebugEvaluationFailure>().having(
              (e) => e.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
        engine.dispose();
        await checked;
        expect(await createDebugEvaluator(sibling).start('6 * 7').result, '42');
        await expectLater(
          evaluator.start('6 * 7').result,
          throwsA(
            isA<DebugEvaluationFailure>().having(
              (e) => e.kind,
              'kind',
              // A new submission to an already disposed engine is rejected;
              // only an accepted pending evaluation was cancelled above.
              FailureKind.failed,
            ),
          ),
        );
      },
    );

    test(
      'display deadline keeps late native success and rejection drainable',
      () async {
        final configured = createDebugEvaluator(engine);
        final evaluator = DebugEvaluator(
          evaluate: configured.evaluate,
          release: configured.release,
          drain: configured.drain,
          timeout: Duration.zero,
        );
        for (final rejected in [false, true]) {
          final task = evaluator.start(
            'new Promise((resolve, reject) => { globalThis.finishDebug = ${rejected ? 'reject' : 'resolve'}; })',
          );
          await expectLater(task.result, throwsA(isA<TimeoutException>()));
          final drained = rejected
              ? expectLater(
                  task.completion,
                  throwsA(isA<DebugEvaluationFailure>()),
                )
              : expectLater(task.completion, completion(contains('callback:')));
          engine.runOwnedCode('void finishDebug({callback: () => 42})');
          await drained.timeout(const Duration(seconds: 3));
          expect(engine.debugOwnedReferenceCount, 0);
        }
      },
    );

    test(
      'arbitrary script side effects never use the read-only retry path',
      () async {
        final evaluator = createDebugEvaluator(engine);
        await expectLater(
          evaluator
              .start(
                'globalThis.attempts = (globalThis.attempts || 0) + 1; throw new Error("Connection reset by peer");',
              )
              .result,
          throwsA(
            isA<DebugEvaluationFailure>().having(
              (e) => e.message,
              'original error',
              contains('Connection reset by peer'),
            ),
          ),
        );
        expect(await evaluator.start('attempts').result, '1');
      },
    );
  }, skip: !nativeAvailable);
}
