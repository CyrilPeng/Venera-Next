import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/image_loading_config.dart';

class _Reference extends JSRef {
  _Reference({this.failure});
  final Object? failure;
  var releases = 0;

  @override
  void destroy() {
    releases++;
    if (failure case final error?) throw error;
  }

  // Distinct native wrappers can have equal values. Ownership must use Dart
  // identity, independently of an adapter's equality implementation.
  @override
  bool operator ==(Object other) => other is _Reference;
  @override
  int get hashCode => 1;
}

void main() {
  test(
    'config transfer uses reference identity and visits keys and cycles',
    () {
      final first = _Reference();
      final shared = _Reference();
      final key = _Reference();
      final cycle = <Object?>[];
      cycle.addAll([cycle, first, shared]);
      final owner = ImageLoadingConfigOwner({key: cycle, 'again': shared});
      owner.replace({'next': shared});
      expect(first.releases, 1);
      expect(key.releases, 1);
      expect(shared.releases, 0);
      owner.dispose();
      owner.dispose();
      expect(shared.releases, 1);
    },
  );

  test('discarded result aliases cannot release a current callback', () {
    final current = _Reference();
    final rejected = _Reference();
    final owner = ImageLoadingConfigOwner({'callback': current});
    owner.discard([current, rejected, rejected]);
    expect(current.releases, 0);
    expect(rejected.releases, 1);
    owner.dispose();
    expect(current.releases, 1);
    expect(rejected.releases, 1);
  });

  test('mutation cannot lose original references or hide newly added ones', () {
    final original = _Reference();
    final added = _Reference();
    final config = <String, Object?>{'old': original};
    final owner = ImageLoadingConfigOwner(config);
    config
      ..clear()
      ..['new'] = added;
    owner.dispose();
    expect(original.releases, 1);
    expect(added.releases, 1);
  });

  test(
    'failed retirement still owns new config and preserves both failures',
    () {
      final retireError = StateError('retire');
      final closeError = StateError('close');
      final previous = _Reference(failure: retireError);
      final next = _Reference(failure: closeError);
      final owner = ImageLoadingConfigOwner(previous);
      Object? failure;
      StackTrace? stack;
      try {
        owner.replace(next);
      } catch (error, trace) {
        failure = error;
        stack = trace;
      }
      expect(failure, isA<ImageLoadingConfigCleanupFailure>());
      expect(previous.releases, 1);
      expect(next.releases, 0);
      expect(
        () => owner.dispose(cause: failure, stackTrace: stack),
        throwsA(
          isA<ImageLoadingConfigFailure>()
              .having((error) => error.cause, 'original cleanup', same(failure))
              .having(
                (error) => error.cleanupFailure.failures.single.error,
                'final cleanup',
                same(closeError),
              ),
        ),
      );
      owner.dispose();
      expect(next.releases, 1);
    },
  );
}
