import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/volume_controller.dart';

ReaderVolumeController controller({
  required ReaderVolumeConnection Function(void Function(Object?)) connect,
  List<String>? actions,
  bool Function()? nextPage,
  bool Function()? previousPage,
  void Function(Object, StackTrace)? onError,
}) => ReaderVolumeController(
  connect: connect,
  nextPage:
      nextPage ??
      () {
        actions?.add('next page');
        return false;
      },
  previousPage:
      previousPage ??
      () {
        actions?.add('previous page');
        return false;
      },
  nextChapter: () => actions?.add('next chapter'),
  previousChapter: () => actions?.add('previous chapter end'),
  onError: onError ?? (_, _) {},
);

class _Lease implements ReaderVolumeConnection {
  _Lease(this.send, {Future<void>? activation, this.release})
    : ready = activation ?? Future.value();
  final void Function(Object?) send;
  @override
  final Future<void> ready;
  Future<void> Function()? release;
  int closes = 0;
  @override
  Future<void> closeAndWait() async {
    closes++;
    await release?.call();
  }
}

void main() {
  test('acknowledged events navigate pages and chapter boundaries', () async {
    late _Lease lease;
    final actions = <String>[];
    var pageAvailable = true;
    final reader = controller(
      connect: (send) => lease = _Lease(send),
      actions: actions,
      nextPage: () {
        actions.add('next page');
        return pageAvailable;
      },
      previousPage: () {
        actions.add('previous page');
        return pageAvailable;
      },
    );
    await reader.setEnabled(true);
    lease.send(1);
    lease.send(2);
    lease.send('unknown');
    pageAvailable = false;
    lease.send(1);
    lease.send(2);
    expect(actions, [
      'previous page',
      'next page',
      'previous page',
      'previous chapter end',
      'next page',
      'next chapter',
    ]);
    await reader.dispose();
    lease.send(2);
    expect(actions, hasLength(6));
  });

  test(
    'replacement awaits cancellation and rejects old generation events',
    () async {
      final cancelled = Completer<void>();
      final leases = <_Lease>[];
      final actions = <String>[];
      final reader = controller(
        connect: (send) {
          final lease = _Lease(
            send,
            release: leases.isEmpty ? () => cancelled.future : null,
          );
          leases.add(lease);
          return lease;
        },
        actions: actions,
      );
      await reader.setEnabled(true);
      await reader.setEnabled(true);
      expect(leases, hasLength(1));
      final off = reader.setEnabled(false);
      leases.single.send(1);
      final on = reader.setEnabled(true);
      leases.single.send(2);
      await Future<void>.delayed(Duration.zero);
      expect(leases, hasLength(1));
      expect(actions, isEmpty);
      cancelled.complete();
      await Future.wait([off, on]);
      expect(leases, hasLength(2));
      leases.first.send(1);
      leases.last.send(2);
      expect(actions, ['next page', 'next chapter']);
      await reader.dispose();
    },
  );

  test(
    'close during activation waits and never delivers or reconnects',
    () async {
      final activation = Completer<void>();
      final cancellation = Completer<void>();
      late _Lease lease;
      final actions = <String>[];
      var connects = 0;
      final reader = controller(
        connect: (send) {
          connects++;
          return lease = _Lease(
            send,
            activation: activation.future,
            release: () => cancellation.future,
          );
        },
        actions: actions,
      );
      final opening = reader.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      lease.send(2);
      final closing = reader.dispose();
      expect(identical(closing, reader.dispose()), isTrue);
      var done = false;
      unawaited(closing.then((_) => done = true));
      activation.complete();
      await Future<void>.delayed(Duration.zero);
      lease.send(1);
      expect(done, isFalse);
      expect(lease.closes, 1);
      cancellation.complete();
      await Future.wait([opening, closing]);
      await reader.setEnabled(true);
      expect(actions, isEmpty);
      expect(connects, 1);
    },
  );

  test(
    'failed release retains original lease and explicit close retries only release',
    () async {
      final error = StateError('native cancel');
      final stack = StackTrace.current;
      var failRelease = true;
      var connects = 0;
      late _Lease lease;
      final errors = <Object>[];
      final reader = controller(
        connect: (send) {
          connects++;
          return lease = _Lease(
            send,
            release: () async {
              if (failRelease) Error.throwWithStackTrace(error, stack);
            },
          );
        },
        onError: (error, _) => errors.add(error),
      );
      await reader.setEnabled(true);
      try {
        await reader.dispose();
        fail('release must fail');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), stack.toString());
      }
      expect(errors, [error]);
      failRelease = false;
      await reader.dispose();
      await reader.dispose();
      expect(lease.closes, 2);
      expect(connects, 1);
    },
  );

  test(
    'activation failure is returned after cleanup; later enable can retry',
    () async {
      final error = StateError('listen');
      final leases = <_Lease>[];
      final reader = controller(
        connect: (send) {
          final lease = _Lease(
            send,
            activation: leases.isEmpty ? Future.error(error) : null,
          );
          leases.add(lease);
          return lease;
        },
      );
      await expectLater(reader.setEnabled(true), throwsA(same(error)));
      expect(leases.single.closes, 1);
      await reader.setEnabled(true);
      expect(leases, hasLength(2));
      await reader.dispose();
    },
  );

  test('activation and cleanup errors retain both causes and stacks', () async {
    final activationError = StateError('listen');
    final cleanupError = StateError('cancel');
    final activationStack = StackTrace.current;
    final cleanupStack = StackTrace.current;
    late _Lease lease;
    final reader = controller(
      connect: (send) => lease = _Lease(
        send,
        activation: Future.error(activationError, activationStack),
        release: () => Future.error(cleanupError, cleanupStack),
      ),
    );
    await expectLater(
      reader.setEnabled(true),
      throwsA(
        isA<ReaderVolumeFailure>()
            .having((f) => f.failures.map((e) => e.error).toList(), 'causes', [
              activationError,
              cleanupError,
            ])
            .having(
              (f) => f.failures.first.stackTrace,
              'activation stack',
              activationStack,
            )
            .having(
              (f) => f.failures.last.stackTrace,
              'cleanup stack',
              cleanupStack,
            ),
      ),
    );
    lease.release = null;
    await reader.dispose();
    expect(lease.closes, 2);
  });

  test(
    'throwing error reporter cannot skip cleanup or replace the original error',
    () async {
      final activationError = StateError('listen');
      final reportError = StateError('report');
      late _Lease lease;
      final reader = controller(
        connect: (send) =>
            lease = _Lease(send, activation: Future.error(activationError)),
        onError: (_, _) => throw reportError,
      );
      await expectLater(
        reader.setEnabled(true),
        throwsA(
          isA<ReaderVolumeFailure>().having(
            (f) => f.failures.map((e) => e.error).toList(),
            'causes',
            [activationError, reportError],
          ),
        ),
      );
      expect(lease.closes, 1);
      await reader.dispose();
    },
  );

  test(
    'failed cancellation prevents replacement activation until release succeeds',
    () async {
      final error = StateError('cancel');
      var failing = true;
      final leases = <_Lease>[];
      final reader = controller(
        connect: (send) {
          final lease = _Lease(
            send,
            release: () async {
              if (failing) throw error;
            },
          );
          leases.add(lease);
          return lease;
        },
      );
      await reader.setEnabled(true);
      await expectLater(reader.setEnabled(false), throwsA(same(error)));
      await expectLater(reader.setEnabled(true), throwsA(same(error)));
      expect(leases, hasLength(1));
      failing = false;
      await reader.setEnabled(true);
      expect(leases, hasLength(2));
      await reader.dispose();
    },
  );

  test(
    'factory and navigation failures are reported without corrupting serial tail',
    () async {
      final error = StateError('factory');
      final navigationError = StateError('navigation');
      var attempts = 0;
      late _Lease lease;
      final errors = <Object>[];
      final reader = controller(
        connect: (send) {
          if (++attempts == 1) throw error;
          return lease = _Lease(send);
        },
        nextPage: () => throw navigationError,
        onError: (e, _) => errors.add(e),
      );
      await expectLater(reader.setEnabled(true), throwsA(same(error)));
      await reader.setEnabled(true);
      lease.send(2);
      expect(errors, [error, navigationError]);
      await reader.dispose();
    },
  );
}
