import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';

void main() {
  test(
    'legacy success, string error and nullable data retain their behavior',
    () {
      const value = Res(3, subData: 'cursor');
      expect(value.success, isTrue);
      expect(value.data, 3);
      expect(value.subData, 'cursor');
      expect(value.failure, isNull);
      const error = Res<int>.error('old error');
      expect(error.error, isTrue);
      expect(error.errorMessage, 'old error');
      expect(error.failure, isNull);
      expect(error.dataOrNull, isNull);
      expect(() => error.data, throwsException);
      const empty = Res<Object?>(null);
      expect(empty.success, isTrue);
      expect(empty.dataOrNull, isNull);
    },
  );

  test(
    'ordinary exception preserves object and stack across result conversion',
    () {
      final cause = StateError('failed');
      final stack = StackTrace.current;
      final original = Res<int>.fromException(cause, stack);
      final converted = Res<String>.fromErrorRes(
        original,
        subData: 'retained cursor',
      );
      expect(converted.failure, same(original.failure));
      expect(converted.failure!.cause, same(cause));
      expect(converted.failure!.stackTrace, same(stack));
      expect(converted.failure!.kind, FailureKind.failed);
      expect(converted.errorMessage, cause.toString());
      expect(converted.dataOrNull, isNull);
      expect(converted.subData, 'retained cursor');
    },
  );

  test(
    'structured cancellation preserves its domain reason and diagnostics',
    () {
      final cause = StateError('transport cancelled');
      final stack = StackTrace.current;
      final failure = SourceFailure(
        SourceFailureCode.cancelled,
        cause: cause,
        stackTrace: stack,
      );
      final result = Res<bool>.fromException(failure, StackTrace.current);
      expect(result.failure, same(failure));
      expect(result.failure!.kind, FailureKind.cancelled);
      expect(result.failure!.cause, same(cause));
      expect(result.failure!.stackTrace, same(stack));
      expect(result.error, isTrue);
      expect(result.success, isFalse);
      expect(result.errorMessage, 'Source update cancelled.');
    },
  );

  test('unsupported exceptions are distinct from ordinary failures', () {
    final cause = UnsupportedError('archive unavailable');
    final result = Res<Object>.fromException(cause, StackTrace.current);
    expect(result.failure!.kind, FailureKind.unsupported);
    expect(result.failure!.cause, same(cause));
    expect(result.errorMessage, cause.toString());
    expect(result.success, isFalse);
    final ordinary = Res<Object>.fromException(
      'unsupported text is not a type',
      StackTrace.current,
    );
    expect(ordinary.failure!.kind, FailureKind.failed);
  });
}
