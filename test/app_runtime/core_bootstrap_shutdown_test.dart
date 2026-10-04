import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';

CoreBootstrap bootstrap({
  List<CoreStartupCleanup> cleanup = const [],
  Future<void> Function()? environment,
  Future<void> Function()? stores,
  Future<void> Function()? finish,
}) => CoreBootstrap(
  environment: environment ?? () async {},
  settings: () async {},
  infrastructure: () async {},
  sources: () async {},
  stores: stores ?? () async {},
  finish: finish ?? () async {},
  failureCleanup: cleanup,
);

void main() {
  test(
    'closing before startup acquires nothing and prevents startup',
    () async {
      final core = bootstrap(
        environment: () async => fail('Closed core cannot start'),
        cleanup: [
          (
            name: 'unacquired',
            close: () => fail('Resource was never acquired'),
          ),
        ],
      );

      final closing = core.close();
      expect(identical(closing, core.close()), isTrue);
      await closing;
      await expectLater(core.start(), throwsStateError);
      expect(identical(closing, core.close()), isTrue);
    },
  );

  test('closing during startup waits for late resources and finish', () async {
    final enteredStores = Completer<void>();
    final ready = Completer<void>();
    final events = <String>[];
    final cleanup = <CoreStartupCleanup>[];
    final core = bootstrap(
      cleanup: cleanup,
      environment: () async {
        cleanup.add((
          name: 'environment',
          close: () => events.add('close env'),
        ));
      },
      stores: () async {
        enteredStores.complete();
        await ready.future;
        cleanup.add((name: 'store', close: () => events.add('close store')));
        events.add('opened store');
      },
      finish: () async {
        events.add('finished startup');
      },
    );

    final starting = core.start();
    await enteredStores.future;
    final closing = core.close();
    var closed = false;
    unawaited(closing.then((_) => closed = true));
    expect(identical(closing, core.close()), isTrue);
    await expectLater(core.start(), throwsStateError);
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(events, isEmpty);

    ready.complete();
    await starting;
    await closing;
    expect(events, [
      'opened store',
      'finished startup',
      'close store',
      'close env',
    ]);
  });

  test(
    'shutdown joins each reverse cleanup and releases resources once',
    () async {
      final draining = Completer<void>();
      final enteredDrain = Completer<void>();
      final events = <String>[];
      final cleanup = <CoreStartupCleanup>[];
      final core = bootstrap(
        cleanup: cleanup,
        stores: () async {
          cleanup.add((name: 'database', close: () => events.add('database')));
        },
        finish: () async {
          cleanup.add((
            name: 'cache',
            close: () async {
              events.add('cache draining');
              enteredDrain.complete();
              await draining.future;
              events.add('cache closed');
            },
          ));
        },
      );
      await core.start();
      expect(events, isEmpty);

      final closing = core.close();
      await enteredDrain.future;
      expect(identical(closing, core.close()), isTrue);
      await expectLater(core.start(), throwsStateError);
      await pumpEventQueue();
      expect(events, ['cache draining']);

      draining.complete();
      await closing;
      await core.close();
      expect(identical(closing, core.close()), isTrue);
      expect(events, ['cache draining', 'cache closed', 'database']);
    },
  );

  test(
    'shutdown retains every cleanup error and still closes earlier owners',
    () async {
      final syncError = StateError('cache close');
      final asyncError = StateError('database close');
      final syncStack = StackTrace.fromString('cache cleanup stack');
      final asyncStack = StackTrace.fromString('database cleanup stack');
      final events = <String>[];
      final core = bootstrap(
        cleanup: [
          (name: 'environment', close: () => events.add('environment')),
          (
            name: 'database',
            close: () async {
              events.add('database');
              await Future<void>.value();
              Error.throwWithStackTrace(asyncError, asyncStack);
            },
          ),
          (
            name: 'cache',
            close: () {
              events.add('cache');
              Error.throwWithStackTrace(syncError, syncStack);
            },
          ),
        ],
      );
      await core.start();

      final closing = core.close();
      late CoreShutdownFailure failure;
      await expectLater(
        closing,
        throwsA(
          isA<CoreShutdownFailure>().having(
            (error) {
              failure = error;
              return error.failures.map((entry) => entry.store).toList();
            },
            'failed owners in cleanup order',
            ['cache', 'database'],
          ),
        ),
      );
      expect(events, ['cache', 'database', 'environment']);
      expect(failure.failures[0].error, same(syncError));
      expect(failure.failures[0].stack.toString(), syncStack.toString());
      expect(failure.failures[1].error, same(asyncError));
      expect(failure.failures[1].stack.toString(), asyncStack.toString());
      expect(identical(closing, core.close()), isTrue);
      await expectLater(core.close(), throwsA(same(failure)));
      expect(events, ['cache', 'database', 'environment']);
      await expectLater(core.start(), throwsStateError);
    },
  );

  test(
    'close joins failed startup rollback without repeating cleanup',
    () async {
      final enteredRollback = Completer<void>();
      final release = Completer<void>();
      final startupError = StateError('finish startup');
      final events = <String>[];
      final core = bootstrap(
        cleanup: [
          (name: 'database', close: () => events.add('database')),
          (
            name: 'cache',
            close: () async {
              events.add('cache draining');
              enteredRollback.complete();
              await release.future;
              events.add('cache closed');
            },
          ),
        ],
        finish: () async => throw startupError,
      );
      final starting = core.start();
      final checked = expectLater(starting, throwsA(same(startupError)));
      await enteredRollback.future;

      final closing = core.close();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(events, ['cache draining']);

      release.complete();
      await checked;
      await closing;
      await core.close();
      expect(events, ['cache draining', 'cache closed', 'database']);
      await expectLater(core.start(), throwsStateError);
    },
  );

  test(
    'failed startup cleanup remains visible to repeated close callers',
    () async {
      final startupError = StateError('finish startup');
      final cleanupError = StateError('database close');
      final cleanupStack = StackTrace.fromString('rollback cleanup stack');
      var closes = 0;
      final core = bootstrap(
        cleanup: [
          (
            name: 'database',
            close: () {
              closes++;
              Error.throwWithStackTrace(cleanupError, cleanupStack);
            },
          ),
        ],
        finish: () async => throw startupError,
      );
      await expectLater(
        core.start(),
        throwsA(
          isA<CoreStartupRollbackFailure>().having(
            (error) => error.cause,
            'startup cause',
            same(startupError),
          ),
        ),
      );

      final closing = core.close();
      late CoreShutdownFailure failure;
      await expectLater(
        closing,
        throwsA(
          isA<CoreShutdownFailure>().having(
            (error) {
              failure = error;
              return error.failures.single.store;
            },
            'failed owner',
            'database',
          ),
        ),
      );
      expect(failure.failures.single.error, same(cleanupError));
      expect(failure.failures.single.stack.toString(), cleanupStack.toString());
      expect(identical(closing, core.close()), isTrue);
      await expectLater(core.close(), throwsA(same(failure)));
      expect(closes, 1);
    },
  );

  test(
    'close preserves store-group rollback errors without retrying stores',
    () async {
      final startupError = StateError('store initialization');
      final storeError = StateError('partial store close');
      final events = <String>[];
      final core = bootstrap(
        cleanup: [
          (name: 'environment', close: () => events.add('environment')),
        ],
        stores: () => initializeCoreStores([
          (
            name: 'partial store',
            initialize: () async => throw startupError,
            close: () {
              events.add('partial store');
              throw storeError;
            },
          ),
        ]),
      );
      await expectLater(
        core.start(),
        throwsA(isA<CoreStartupRollbackFailure>()),
      );
      await expectLater(
        core.close(),
        throwsA(
          isA<CoreShutdownFailure>()
              .having(
                (error) => error.failures.single.store,
                'owner',
                'partial store',
              )
              .having(
                (error) => error.failures.single.error,
                'error',
                same(storeError),
              ),
        ),
      );
      expect(events, ['partial store', 'environment']);
    },
  );

  test(
    'close retains inner and outer rollback failures without retrying either',
    () async {
      final startupError = StateError('store initialization');
      final storeError = StateError('partial store close');
      final environmentError = StateError('environment close');
      final storeStack = StackTrace.fromString('store group rollback stack');
      final environmentStack = StackTrace.fromString(
        'environment rollback stack',
      );
      final events = <String>[];
      final core = bootstrap(
        cleanup: [
          (
            name: 'environment',
            close: () {
              events.add('environment');
              Error.throwWithStackTrace(environmentError, environmentStack);
            },
          ),
        ],
        stores: () => initializeCoreStores([
          (
            name: 'partial store',
            initialize: () async => throw startupError,
            close: () {
              events.add('partial store');
              Error.throwWithStackTrace(storeError, storeStack);
            },
          ),
        ]),
      );
      await expectLater(
        core.start(),
        throwsA(
          isA<CoreStartupRollbackFailure>().having(
            (error) => error.cause,
            'inner store failure',
            isA<CoreStartupRollbackFailure>().having(
              (error) => error.cause,
              'original startup cause',
              same(startupError),
            ),
          ),
        ),
      );

      final closing = core.close();
      late CoreShutdownFailure failure;
      await expectLater(
        closing,
        throwsA(
          isA<CoreShutdownFailure>().having(
            (error) {
              failure = error;
              return error.failures.map((entry) => entry.store).toList();
            },
            'all failed owners',
            unorderedEquals(['partial store', 'environment']),
          ),
        ),
      );
      final byOwner = {
        for (final entry in failure.failures) entry.store: entry,
      };
      expect(byOwner['partial store']!.error, same(storeError));
      expect(byOwner['partial store']!.stack.toString(), storeStack.toString());
      expect(byOwner['environment']!.error, same(environmentError));
      expect(
        byOwner['environment']!.stack.toString(),
        environmentStack.toString(),
      );
      expect(identical(closing, core.close()), isTrue);
      await expectLater(core.close(), throwsA(same(failure)));
      expect(events, ['partial store', 'environment']);
    },
  );
}
