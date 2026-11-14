import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/selection_operation.dart';

Future<void> pumpSidebar(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> settleSidebarWork(
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
  expectSync(done, isTrue, reason: 'The original sidebar work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Iterable<Object> sidebarCauses(Object error) sync* {
  yield error;
  if (error is SelectionCleanupFailure) {
    if (error.operationError != null) {
      yield* sidebarCauses(error.operationError!);
    }
    for (final failure in error.failures) {
      if (failure case (error: final Object cause, stack: final StackTrace _)) {
        yield* sidebarCauses(cause);
      } else {
        yield* sidebarCauses(failure);
      }
    }
  }
}
