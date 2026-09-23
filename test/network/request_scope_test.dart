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
}
