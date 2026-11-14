import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitForEditor(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    if (find.byType(TextField).evaluate().isNotEmpty) return;
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }
  fail('The syntax highlighter did not finish loading.');
}

Future<void> drain(WidgetTester tester, Future<void> Function() action) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final result = action().then<void>(
    (_) => done = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      done = true;
    },
  );
  await pumpUntil(tester, () => done);
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Source editor operation did not settle.');
}
