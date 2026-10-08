import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_engine.dart';

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

void main() {
  test(
    'synchronous descendants cannot free a later root alias twice',
    () async {
      final reference = _Reference();
      final graph = [
        SynchronousFuture<Object?>([reference]),
        reference,
      ];
      discardJsResult(graph);
      await drainJsResultDescendants(graph);
      expect(reference.destroys, 1);
    },
  );

  test(
    'root aliases, map keys, cycles and repeated Futures release once',
    () async {
      final rootReference = _Reference();
      final next = _Reference();
      final response = Completer<Object?>();
      final graph = <Object, Object?>{
        rootReference: rootReference,
        'future': response.future,
        'alias': response.future,
      };
      graph['self'] = graph;
      discardJsResult(graph);
      final drain = drainJsResultDescendants(graph);
      expect(rootReference.destroys, 1);
      final resolved = <Object, Object?>{
        next: [next, rootReference, graph],
      };
      resolved['self'] = resolved;
      response.complete(resolved);
      await drain;
      expect([rootReference.destroys, next.destroys], [1, 1]);
    },
  );

  test(
    'siblings drain as they settle without waiting on the first Promise',
    () async {
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      final graph = [first.future, second.future];
      discardJsResult(graph);
      var complete = false;
      final drain = drainJsResultDescendants(
        graph,
      ).then((_) => complete = true);
      final fast = _Reference();
      second.complete(fast);
      await Future<void>.delayed(Duration.zero);
      expect(fast.destroys, 1);
      expect(complete, isFalse);
      final slow = _Reference();
      first.complete(slow);
      await drain;
      expect(slow.destroys, 1);
    },
  );

  test(
    'new descendants and rejected graphs are joined with original stacks',
    () async {
      final parent = Completer<Object?>();
      final child = Completer<Object?>();
      final sibling = Completer<Object?>();
      final graph = [parent.future, sibling.future];
      discardJsResult(graph);
      final errors = <Object>[];
      var complete = false;
      final drain = drainJsResultDescendants(graph).then<void>(
        (_) => complete = true,
        onError: (Object error) {
          errors.add(error);
          complete = true;
        },
      );
      parent.complete({child.future: child.future});
      await Future<void>.delayed(Duration.zero);
      final reference = _Reference();
      final rejection = {
        reference: [reference],
      };
      final stack = StackTrace.fromString('nested rejection stack');
      child.completeError(rejection, stack);
      await Future<void>.delayed(Duration.zero);
      expect(reference.destroys, 1);
      expect(complete, isFalse);
      sibling.complete(null);
      await drain;
      final failure = errors.single as JsResourceReleaseFailure;
      expect(failure.failures, hasLength(1));
      expect(failure.failures.single.error, same(rejection));
      expect(failure.failures.single.stack.toString(), stack.toString());
    },
  );

  test(
    'rejection plus release failures do not skip other references',
    () async {
      final response = Completer<Object?>();
      final releaseError = StateError('release failed');
      final broken = _Reference(failure: releaseError);
      final good = _Reference();
      final graph = [response.future];
      discardJsResult(graph);
      final drain = drainJsResultDescendants(graph);
      final rejection = {
        'bad': broken,
        good: [good, broken],
      };
      final checked = expectLater(
        drain,
        throwsA(
          isA<JsResourceReleaseFailure>().having(
            (e) => e.failures.map((f) => f.error).toList(),
            'both errors',
            [rejection, releaseError],
          ),
        ),
      );
      response.completeError(rejection);
      await checked;
      expect([broken.destroys, good.destroys], [1, 1]);
    },
  );

  test('a failed root free is not retried through a later alias', () async {
    final broken = _Reference(failure: StateError('root release'));
    final response = Completer<Object?>();
    final graph = [broken, response.future];
    expect(
      () => discardJsResult(graph),
      throwsA(isA<JsResourceReleaseFailure>()),
    );
    final drain = drainJsResultDescendants(graph);
    final fresh = _Reference();
    response.complete([broken, fresh]);
    await drain;
    expect([broken.destroys, fresh.destroys], [1, 1]);
  });
}
