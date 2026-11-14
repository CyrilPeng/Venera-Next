import 'package:flutter_test/flutter_test.dart';

Future<void> drainUi(
  WidgetTester tester,
  Future<void> Function() action,
) async {
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
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expectSync(done, isTrue, reason: 'The original UI work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}
