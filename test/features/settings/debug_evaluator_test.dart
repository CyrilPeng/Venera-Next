import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/debug_evaluator.dart';
import 'package:venera_next/foundation/operation_failure.dart';

class _BadText {
  _BadText(this.error);
  final Object error;
  @override
  String toString() => throw error;
}

void main() {
  test('display is independent of descendant cleanup completion', () async {
    final cleanup = Completer<void>();
    Object? released;
    final task = DebugEvaluator(
      evaluate: (_) => {'value': 42},
      release: (graph) => released = graph,
      drain: (graph) {
        expect(graph, same(released));
        return cleanup.future;
      },
    ).start('object');
    expect(await task.result, '{\n  "value": 42\n}');
    var completed = false;
    final completion = task.completion.then((_) => completed = true);
    await pumpEventQueue();
    expect(completed, isFalse);
    cleanup.complete();
    await completion;
  });

  test('root and both cleanup failures retain errors and stacks', () async {
    final root = StateError('evaluation');
    final rootStack = StackTrace.fromString('evaluation stack');
    final release = StateError('synchronous release');
    final releaseStack = StackTrace.fromString('release stack');
    final drain = StateError('descendant cleanup');
    final drainStack = StackTrace.fromString('descendant stack');
    final cleanup = Completer<void>();
    final task = DebugEvaluator(
      evaluate: (_) => Error.throwWithStackTrace(root, rootStack),
      release: (_) => Error.throwWithStackTrace(release, releaseStack),
      drain: (graph) {
        expect((graph as List)[1], same(root));
        return cleanup.future;
      },
    ).start('failure');
    await expectLater(
      task.result,
      throwsA(
        isA<DebugEvaluationFailure>().having(
          (e) => e.cleanupFailures.single.error,
          'initial cleanup',
          same(release),
        ),
      ),
    );
    final checked = expectLater(
      task.completion,
      throwsA(
        isA<DebugEvaluationFailure>()
            .having((e) => e.cause, 'original cause', same(root))
            .having(
              (e) => e.stackTrace.toString(),
              'original stack',
              rootStack.toString(),
            )
            .having(
              (e) => e.cleanupFailures.map((f) => f.error).toList(),
              'all cleanup errors',
              [release, drain],
            )
            .having(
              (e) => e.cleanupFailures.map((f) => f.stack.toString()).toList(),
              'all cleanup stacks',
              [releaseStack.toString(), drainStack.toString()],
            ),
      ),
    );
    cleanup.completeError(drain, drainStack);
    await checked;
  });

  test(
    'late cleanup failure cannot replace an already displayed result',
    () async {
      final cleanup = Completer<void>();
      final cause = StateError('late cleanup');
      final task = DebugEvaluator(
        evaluate: (_) => 42,
        release: (_) {},
        drain: (_) => cleanup.future,
      ).start('value');
      expect(await task.result, '42');
      cleanup.completeError(cause);
      // A display-only caller must not receive an unhandled late failure.
      await pumpEventQueue();
      expect(await task.result, '42');
      await expectLater(
        task.completion,
        throwsA(
          isA<DebugEvaluationFailure>().having(
            (e) => e.cause,
            'cause',
            same(cause),
          ),
        ),
      );
    },
  );

  test('a display timeout still joins descendants returned later', () async {
    final response = Completer<Object?>();
    final cleanup = Completer<void>();
    var drained = false;
    final task = DebugEvaluator(
      evaluate: (_) => response.future,
      release: (_) {},
      drain: (_) {
        drained = true;
        return cleanup.future;
      },
      timeout: Duration.zero,
    ).start('pending');
    await expectLater(task.result, throwsA(isA<TimeoutException>()));
    response.complete(42);
    var completed = false;
    final completion = task.completion.then((_) => completed = true);
    await pumpEventQueue();
    expect(drained, isTrue);
    expect(completed, isFalse);
    cleanup.complete();
    await completion;
  });

  test('a synchronous drain failure retains the root cause', () async {
    final cause = StateError('evaluation');
    final cleanup = StateError('cannot subscribe');
    final task = DebugEvaluator(
      evaluate: (_) => throw cause,
      release: (_) {},
      drain: (_) => throw cleanup,
    ).start('failure');
    await expectLater(
      task.result,
      throwsA(
        isA<DebugEvaluationFailure>()
            .having((e) => e.cause, 'cause', same(cause))
            .having(
              (e) => e.cleanupFailures.single.error,
              'cleanup',
              same(cleanup),
            ),
      ),
    );
  });

  test(
    'formats detached values and lends the result to cleanup once',
    () async {
      for (final (value, expected) in <(Object?, String)>[
        (null, 'null'),
        (42, '42'),
        ('text', 'text'),
        (<String, Object?>{'chapters': 3}, '{\n  "chapters": 3\n}'),
        (<int>[1, 2], '[\n  1,\n  2\n]'),
        (<int, String>{1: 'non-string key'}, '{1: non-string key}'),
      ]) {
        final released = <Object?>[];
        final evaluator = DebugEvaluator(
          evaluate: (_) => value,
          release: released.add,
        );
        final task = evaluator.start('submitted');
        expect(await task.result, expected);
        expect(await task.completion, expected);
        expect(released, hasLength(1));
        expect((released.single as List).first, same(value));
      }
    },
  );

  test(
    'an unresolved Promise retains ownership until actual completion',
    () async {
      final response = Completer<Object?>();
      final released = <Object?>[];
      final codes = <String>[];
      final evaluator = DebugEvaluator(
        evaluate: (code) {
          codes.add(code);
          return response.future;
        },
        release: released.add,
      );
      final task = evaluator.start('original code');
      await Future<void>.delayed(Duration.zero);
      expect(codes, ['original code']);
      expect(released, isEmpty);
      response.complete({'value': 7});
      expect(await task.result, '{\n  "value": 7\n}');
      expect(released, hasLength(1));
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'failure preserves original error/stack and releases it; async=$asynchronous',
      () async {
        final cause = <String, Object>{'rejection': Object()};
        final stack = StackTrace.fromString('original evaluation stack');
        final released = <Object?>[];
        final evaluator = DebugEvaluator(
          evaluate: (_) => asynchronous
              ? Future<Object?>.error(cause, stack)
              : Error.throwWithStackTrace(cause, stack),
          release: released.add,
        );
        await expectLater(
          evaluator.start('throw').result,
          throwsA(
            isA<DebugEvaluationFailure>()
                .having((e) => e.cause, 'cause', same(cause))
                .having(
                  (e) => e.stackTrace.toString(),
                  'stack',
                  stack.toString(),
                )
                .having((e) => e.message, 'message', cause.toString()),
          ),
        );
        expect((released.single as List)[1], same(cause));
      },
    );
  }

  test('formatting and cleanup failures are both retained', () async {
    final format = StateError('cannot format');
    final cleanup = StateError('cannot release');
    final cleanupStack = StackTrace.fromString('cleanup stack');
    final value = _BadText(format);
    final evaluator = DebugEvaluator(
      evaluate: (_) => value,
      release: (graph) {
        expect((graph as List).first, same(value));
        Error.throwWithStackTrace(cleanup, cleanupStack);
      },
    );
    await expectLater(
      evaluator.start('value').result,
      throwsA(
        isA<DebugEvaluationFailure>()
            .having((e) => e.cause, 'original format error', same(format))
            .having(
              (e) => e.cleanupFailures.single.error,
              'cleanup error',
              same(cleanup),
            )
            .having(
              (e) => e.cleanupFailures.single.stack.toString(),
              'cleanup stack',
              cleanupStack.toString(),
            )
            .having(
              (e) => e.message,
              'both diagnostics',
              allOf(contains('cannot format'), contains('cannot release')),
            ),
      ),
    );
  });

  test('an error whose toString throws cannot skip cleanup', () async {
    final cause = _BadText(StateError('bad error string'));
    var released = false;
    final evaluator = DebugEvaluator(
      evaluate: (_) => throw cause,
      release: (graph) {
        expect((graph as List)[1], same(cause));
        released = true;
      },
    );
    await expectLater(
      evaluator.start('throw').result,
      throwsA(
        isA<DebugEvaluationFailure>().having(
          (e) => e.cause,
          'cause',
          same(cause),
        ),
      ),
    );
    expect(released, isTrue);
  });

  test('cleanup failure prevents a successful result', () async {
    final cause = StateError('cleanup');
    final evaluator = DebugEvaluator(
      evaluate: (_) => 42,
      release: (_) => throw cause,
    );
    await expectLater(
      evaluator.start('42').result,
      throwsA(
        isA<DebugEvaluationFailure>().having(
          (e) => e.cleanupFailures.single.error,
          'cleanup',
          same(cause),
        ),
      ),
    );
  });

  test(
    'display timeout leaves original completion and late cleanup observable',
    () async {
      final response = Completer<Object?>();
      final released = <Object?>[];
      final evaluator = DebugEvaluator(
        evaluate: (_) => response.future,
        release: released.add,
        timeout: Duration.zero,
      );
      final task = evaluator.start('pending');
      await expectLater(task.result, throwsA(isA<TimeoutException>()));
      expect(released, isEmpty);
      response.complete('late');
      expect(await task.completion, 'late');
      expect(released, hasLength(1));
    },
  );

  test(
    'late rejection and release failures remain available after timeout',
    () async {
      final response = Completer<Object?>();
      final cause = StateError('late rejection');
      final cleanup = StateError('late release');
      final evaluator = DebugEvaluator(
        evaluate: (_) => response.future,
        release: (_) => throw cleanup,
        timeout: Duration.zero,
      );
      final task = evaluator.start('pending');
      await expectLater(task.result, throwsA(isA<TimeoutException>()));
      final completed = expectLater(
        task.completion,
        throwsA(
          isA<DebugEvaluationFailure>()
              .having((e) => e.cause, 'cause', same(cause))
              .having(
                (e) => e.cleanupFailures.single.error,
                'cleanup',
                same(cleanup),
              ),
        ),
      );
      response.completeError(cause);
      await completed;
    },
  );

  test(
    'cancellation remains distinct and arbitrary debug code is never retried',
    () async {
      var calls = 0;
      const stopped = OperationFailure(
        message: 'closed',
        kind: FailureKind.cancelled,
      );
      final evaluator = DebugEvaluator(
        evaluate: (_) {
          calls++;
          throw stopped;
        },
        release: (_) {},
      );
      await expectLater(
        evaluator.start('side effects').result,
        throwsA(
          isA<DebugEvaluationFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      expect(calls, 1);
    },
  );
}
