import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ArchiveInfo;

ArchiveInfo option([String id = 'original']) => ArchiveInfo.fromJson({
  'id': id,
  'title': 'Archive $id',
  'description': 'Synthetic choice',
});

Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> drainArchiveWork(
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
  expectSync(done, isTrue, reason: 'The original archive work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}
