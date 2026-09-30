import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/orientation_controller.dart';

void main() {
  test('only the top owner rotates and removal restores the previous lock', () {
    final requests = <ReaderOrientation>[];
    final coordinator = ReaderOrientationCoordinator(
      apply: (value) async => requests.add(value),
      onError: (error, stack) => fail('$error'),
    );
    final first = coordinator.acquire();
    expect(first.cycle(), isTrue);
    final second = coordinator.acquire();
    expect(first.cycle(), isFalse);
    second.cycle();
    second.cycle();
    second.dispose();
    expect(requests.last, ReaderOrientation.portrait);
    first.dispose();
    first.dispose();
    expect(requests, [
      ReaderOrientation.system,
      ReaderOrientation.portrait,
      ReaderOrientation.system,
      ReaderOrientation.portrait,
      ReaderOrientation.landscape,
      ReaderOrientation.portrait,
      ReaderOrientation.system,
    ]);
    coordinator.dispose();
  });

  test(
    'independent scopes retain no shared state and disposing an old owner does not publish',
    () {
      final a = <ReaderOrientation>[];
      final b = <ReaderOrientation>[];
      final first = ReaderOrientationCoordinator(
        apply: (value) async => a.add(value),
        onError: (error, stack) => fail('$error'),
      );
      final second = ReaderOrientationCoordinator(
        apply: (value) async => b.add(value),
        onError: (error, stack) => fail('$error'),
      );
      final old = first.acquire();
      final current = first.acquire();
      current.cycle();
      old.dispose();
      final other = second.acquire();
      other.cycle();
      expect(a, [
        ReaderOrientation.system,
        ReaderOrientation.system,
        ReaderOrientation.portrait,
      ]);
      first.dispose();
      expect(current.cycle(), isFalse);
      expect(() => first.acquire(), throwsStateError);
      expect(other.cycle(), isTrue);
      expect(b.last, ReaderOrientation.landscape);
      current.dispose();
      expect(a.last, ReaderOrientation.system);
      second.dispose();
    },
  );

  test(
    'pending requests do not block release and failures are reported',
    () async {
      final pending = <Completer<void>>[];
      final requests = <ReaderOrientation>[];
      final errors = <Object>[];
      final coordinator = ReaderOrientationCoordinator(
        apply: (value) {
          requests.add(value);
          final request = Completer<void>();
          pending.add(request);
          return request.future;
        },
        onError: (error, stack) => errors.add(error),
      );
      final owner = coordinator.acquire();
      owner.cycle();
      coordinator.dispose();
      owner.dispose();
      expect(requests, [
        ReaderOrientation.system,
        ReaderOrientation.portrait,
        ReaderOrientation.system,
      ]);
      pending.last.complete();
      pending[1].completeError(StateError('platform'));
      pending.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      expect(owner.cycle(), isFalse);
      expect(requests.last, ReaderOrientation.system);
    },
  );
}
