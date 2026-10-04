import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  test('cancel reaches child HTTP token and suppresses late results', () async {
    final parent = RequestScope();
    final child = RequestScope(parent: parent);
    final response = Completer<int>();
    final result = child.run(() {
      expect(RequestScope.current, same(child));
      return response.future;
    });
    final check = expectLater(result, throwsA(isA<RequestCancelled>()));
    parent.cancel();
    await check;
    expect(child.cancelToken.isCancelled, isTrue);
    response.complete(42);
    child.dispose();
    parent.dispose();
  });

  test('deadline completes a hung call and cancels its HTTP token', () async {
    final scope = RequestScope(timeout: const Duration(milliseconds: 5));
    await expectLater(
      scope.run(() => Completer<void>().future),
      throwsA(isA<TimeoutException>()),
    );
    expect(scope.cancelToken.isCancelled, isTrue);
    scope.dispose();
  });

  test(
    'completion wait retains the zone and joins a cancelled action',
    () async {
      final parent = RequestScope();
      final child = RequestScope(parent: parent);
      final response = Completer<int>();
      var settled = false;
      final result = child.runToCompletion(() async {
        expect(RequestScope.current, same(child));
        final value = await response.future;
        expect(RequestScope.current, same(child));
        expect(RequestScope.current!.cancelToken, same(child.cancelToken));
        return value;
      });
      final check = expectLater(
        result,
        throwsA(isA<RequestCancelled>()),
      ).then((_) => settled = true);
      parent.cancel();
      await pumpEventQueue();
      expect(child.cancelToken.isCancelled, true);
      expect(settled, false);
      response.complete(42);
      await check;
      expect(RequestScope.current, isNull);
      child.dispose();
      parent.dispose();
    },
  );

  test(
    'completion wait preserves a late failure and its original stack',
    () async {
      final scope = RequestScope();
      final response = Completer<int>();
      final failure = StateError('late action failure');
      final stack = StackTrace.fromString('action stack');
      final result = scope.runToCompletion(() => response.future);
      final observed = result.then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace actualStack) {
          expect(error, same(failure));
          expect(actualStack, same(stack));
          return error;
        },
      );
      scope.cancel();
      response.completeError(failure, stack);
      expect(await observed, same(failure));
      scope.dispose();
    },
  );

  test('completion wait refuses work cancelled before admission', () async {
    final scope = RequestScope()..cancel();
    var calls = 0;
    await expectLater(
      scope.runToCompletion(() => calls++),
      throwsA(isA<RequestCancelled>()),
    );
    expect(calls, 0);
    scope.dispose();
  });

  test(
    'completion deadline cancels immediately but still joins the action',
    () async {
      final scope = RequestScope(timeout: const Duration(milliseconds: 5));
      final response = Completer<void>();
      var settled = false;
      final expected = expectLater(
        scope.runToCompletion(() => response.future),
        throwsA(isA<TimeoutException>()),
      ).then((_) => settled = true);
      await scope.whenCancelled;
      await pumpEventQueue();
      expect(scope.cancelToken.isCancelled, true);
      expect(settled, false);
      response.complete();
      await expected;
      scope.dispose();
    },
  );

  test(
    'completion wait keeps synchronous success and failure semantics',
    () async {
      final scope = RequestScope();
      expect(await scope.runToCompletion(() => 42), 42);
      final failure = StateError('synchronous failure');
      await expectLater(
        scope.runToCompletion(() => throw failure),
        throwsA(same(failure)),
      );
      scope.dispose();
    },
  );
}
