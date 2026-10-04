import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/shared_image_requests.dart';

class _GatedSource {
  _GatedSource({this.failure, this.failureStack});

  final Object? failure;
  final StackTrace? failureStack;
  final started = Completer<RequestScope>();
  final cleaning = Completer<void>();
  final cleanup = Completer<void>();
  var starts = 0;

  Stream<int> stream(RequestScope scope) async* {
    starts++;
    started.complete(scope);
    try {
      await scope.whenCancelled;
      scope.check();
    } finally {
      cleaning.complete();
      await cleanup.future;
      if (failure case final error?) {
        Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
      }
    }
  }

  void finish() {
    if (!cleanup.isCompleted) cleanup.complete();
  }
}

Future<void> _rejected(SharedImageRequests<int> requests) => expectLater(
  Future<void>.sync(() async {
    await requests.open((_) {
      fail('Held requests must not start a source');
    }, key: 'rejected').drain<void>();
  }),
  throwsA(anything),
);

void main() {
  final registries = <SharedImageRequests<int>>[];
  final sources = <_GatedSource>[];

  SharedImageRequests<int> registry() {
    final value = SharedImageRequests<int>();
    registries.add(value);
    return value;
  }

  _GatedSource source({Object? failure, StackTrace? stack}) {
    final value = _GatedSource(failure: failure, failureStack: stack);
    sources.add(value);
    return value;
  }

  tearDown(() async {
    for (final source in sources) {
      source.finish();
    }
    for (final requests in registries) {
      try {
        await requests.cancelAll();
      } catch (_) {
        // Tests observe expected cleanup failures before teardown.
      }
    }
    sources.clear();
    registries.clear();
  });

  test(
    'same-key replacement retains the retired source until finally ends',
    () async {
      final requests = registry();
      final old = source();
      final current = source();
      final first = requests.open(old.stream, key: 'image').listen((_) {});
      await old.started.future;
      first.cancel().ignore();
      await old.cleaning.future;
      requests.open(current.stream, key: 'image').listen((_) {});
      await current.started.future;

      var prepared = false;
      final preparing = requests.prepareForExit();
      preparing.then((_) => prepared = true);
      await current.cleaning.future;
      current.finish();
      await pumpEventQueue();
      expect(prepared, isFalse);
      old.finish();
      final release = await preparing;
      expect(prepared, isTrue);
      expect(old.starts, 1);
      expect(current.starts, 1);
      release();
    },
  );

  test(
    'one shared owner can leave without cancelling another owner or registry',
    () async {
      final requests = registry();
      final independent = registry();
      final sharedSource = source();
      final independentSource = source();
      final first = requests
          .open(sharedSource.stream, key: 'image')
          .listen((_) {});
      final second = requests
          .open((_) {
            fail('The existing key must reuse its source');
          }, key: 'image')
          .listen((_) {});
      independent.open(independentSource.stream, key: 'image').listen((_) {});
      final sharedScope = await sharedSource.started.future;
      final independentScope = await independentSource.started.future;
      await first.cancel();
      expect(sharedScope.isCancelled, isFalse);
      final preparing = requests.prepareForExit();
      await sharedSource.cleaning.future;
      expect(independentScope.isCancelled, isFalse);
      sharedSource.finish();
      (await preparing)();
      await second.cancel();
      expect(independentSource.cleaning.isCompleted, isFalse);
    },
  );

  test(
    'unkeyed calls own independent requests and both join preparation',
    () async {
      final requests = registry();
      final first = source();
      final second = source();
      requests.open(first.stream).listen((_) {});
      requests.open(second.stream).listen((_) {});
      await Future.wait([first.started.future, second.started.future]);
      var prepared = false;
      final preparing = requests.prepareForExit();
      preparing.then((_) => prepared = true);
      await Future.wait([first.cleaning.future, second.cleaning.future]);
      first.finish();
      await pumpEventQueue();
      expect(prepared, isFalse);
      second.finish();
      (await preparing)();
    },
  );

  test('each preparation has an independent idempotent hold', () async {
    final requests = registry();
    final pending = source();
    requests.open(pending.stream).listen((_) {});
    await pending.started.future;
    final first = requests.prepareForExit();
    final second = requests.prepareForExit();
    await pending.cleaning.future;
    await _rejected(requests);
    pending.finish();
    final releaseFirst = await first;
    final releaseSecond = await second;
    releaseFirst();
    releaseFirst();
    await _rejected(requests);
    releaseSecond();
    expect(await requests.open((_) => Stream.value(1)).single, 1);

    final releaseCurrent = await requests.prepareForExit();
    releaseFirst();
    releaseSecond();
    await _rejected(requests);
    releaseCurrent();
    expect(await requests.open((_) => Stream.value(2)).single, 2);
  });

  test(
    'unlistened handles cannot start after preparation or its release',
    () async {
      final requests = registry();
      var starts = 0;
      Stream<int> open() => requests.open((_) {
        starts++;
        return Stream.value(1);
      }, key: Object());
      final duringHold = open();
      final afterRelease = open();
      expect(starts, 0);
      final release = await requests.prepareForExit();
      expect(await duringHold.toList(), isEmpty);
      release();
      expect(await afterRelease.toList(), isEmpty);
      expect(starts, 0);
      expect(await open().single, 1);
      expect(starts, 1);
    },
  );

  test(
    'cancelAll drains its snapshot without freezing later requests',
    () async {
      final requests = registry();
      final first = source();
      final later = source();
      requests.open(first.stream, key: 'first').listen((_) {});
      await first.started.future;
      final cancelling = requests.cancelAll();
      await first.cleaning.future;
      requests.open(later.stream, key: 'later').listen((_) {});
      final laterScope = await later.started.future;
      first.finish();
      await cancelling;
      expect(laterScope.isCancelled, isFalse);
      expect(later.cleaning.isCompleted, isFalse);
    },
  );

  test(
    'preparation preserves retired and current failures and waits for all cleanup',
    () async {
      final requests = registry();
      final oldError = StateError('retired cleanup');
      final currentError = StateError('current cleanup');
      final old = source(
        failure: oldError,
        stack: StackTrace.fromString('old stack'),
      );
      final current = source(
        failure: currentError,
        stack: StackTrace.fromString('current stack'),
      );
      final slow = source();
      final subscription = requests.open(old.stream, key: 'old').listen((_) {});
      await old.started.future;
      subscription.cancel().ignore();
      await old.cleaning.future;
      old.finish();
      await pumpEventQueue();
      requests.open(current.stream, key: 'current').listen((_) {});
      requests.open(slow.stream, key: 'slow').listen((_) {});
      await Future.wait([current.started.future, slow.started.future]);

      var ended = false;
      final preparing = requests.prepareForExit();
      final checked = expectLater(
        preparing,
        throwsA(
          isA<SharedImageRequestFailure>()
              .having(
                (failure) => failure.failures.map((entry) => entry.error),
                'all causes',
                unorderedEquals([oldError, currentError]),
              )
              .having(
                (failure) =>
                    failure.failures.map((entry) => entry.stack.toString()),
                'original stacks',
                unorderedEquals(['old stack', 'current stack']),
              ),
        ),
      ).then((_) => ended = true);
      await Future.wait([current.cleaning.future, slow.cleaning.future]);
      current.finish();
      await pumpEventQueue();
      expect(ended, isFalse);
      await _rejected(requests);
      slow.finish();
      await checked;
      expect(await requests.open((_) => Stream.value(7)).single, 7);
      (await requests.prepareForExit())();
    },
  );

  test('source data failure does not become a later cleanup failure', () async {
    final requests = registry();
    final failure = StateError('image load');
    await expectLater(
      requests.open((_) => Stream<int>.error(failure), key: 'image').toList(),
      throwsA(same(failure)),
    );
    (await requests.prepareForExit())();
    expect(await requests.open((_) => Stream.value(8), key: 'image').single, 8);
  });
}
