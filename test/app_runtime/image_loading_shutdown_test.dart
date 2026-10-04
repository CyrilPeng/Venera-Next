import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/image_loading.dart';

void main() {
  test(
    'both preparations start synchronously and release requests before providers',
    () async {
      final providers = Completer<void Function()>();
      final requests = Completer<void Function()>();
      final events = <String>[];
      var prepared = false;
      final preparing = prepareImageLoadingForExit(
        prepareProviders: () {
          events.add('prepare providers');
          return providers.future;
        },
        prepareRequests: () {
          events.add('prepare requests');
          return requests.future;
        },
      );
      expect(events, ['prepare providers', 'prepare requests']);
      preparing.then((_) => prepared = true);
      requests.complete(() => events.add('release requests'));
      await pumpEventQueue();
      expect(prepared, isFalse);
      providers.complete(() => events.add('release providers'));
      final release = await preparing;
      expect(events, ['prepare providers', 'prepare requests']);
      release();
      release();
      expect(events, [
        'prepare providers',
        'prepare requests',
        'release requests',
        'release providers',
      ]);
    },
  );

  for (final failingStage in ['providers', 'requests']) {
    test(
      'synchronous $failingStage failure still waits for and releases the other hold',
      () async {
        final other = Completer<void Function()>();
        final failure = StateError('prepare $failingStage');
        final events = <String>[];
        var ended = false;
        Future<void Function()> prepare(String stage) {
          events.add('prepare $stage');
          if (stage == failingStage) throw failure;
          return other.future;
        }

        final preparing = prepareImageLoadingForExit(
          prepareProviders: () => prepare('providers'),
          prepareRequests: () => prepare('requests'),
        );
        final checked = expectLater(
          preparing,
          throwsA(
            isA<ImageLoadingPreparationFailure>().having(
              (error) => error.failures.map((entry) => entry.error),
              'original preparation failure',
              [same(failure)],
            ),
          ),
        ).then((_) => ended = true);
        expect(events, ['prepare providers', 'prepare requests']);
        await pumpEventQueue();
        expect(ended, isFalse);
        expect(events, ['prepare providers', 'prepare requests']);
        other.complete(() => events.add('release successful hold'));
        await checked;
        expect(events.last, 'release successful hold');
      },
    );
  }

  test(
    'both asynchronous failures retain stage, original cause and stack',
    () async {
      final providers = Completer<void Function()>();
      final requests = Completer<void Function()>();
      final providerFailure = StateError('provider failure');
      final requestFailure = StateError('request failure');
      final preparing = prepareImageLoadingForExit(
        prepareProviders: () => providers.future,
        prepareRequests: () => requests.future,
      );
      final checked = expectLater(
        preparing,
        throwsA(
          isA<ImageLoadingPreparationFailure>()
              .having(
                (error) => error.failures.map((entry) => entry.error),
                'causes',
                unorderedEquals([providerFailure, requestFailure]),
              )
              .having(
                (error) =>
                    error.failures.map((entry) => entry.stack.toString()),
                'stacks',
                unorderedEquals(['provider stack', 'request stack']),
              )
              .having(
                (error) => error.failures.map((entry) => entry.stage).toSet(),
                'distinct stages',
                hasLength(2),
              )
              .having(
                (error) =>
                    error.failures.every((entry) => entry.stage.isNotEmpty),
                'named stages',
                isTrue,
              ),
        ),
      );
      requests.completeError(
        requestFailure,
        StackTrace.fromString('request stack'),
      );
      await pumpEventQueue();
      providers.completeError(
        providerFailure,
        StackTrace.fromString('provider stack'),
      );
      await checked;
    },
  );

  for (final failingStage in ['providers', 'requests']) {
    test(
      '$failingStage preparation failure also preserves rollback failure',
      () async {
        final prepareFailure = StateError('prepare $failingStage');
        final releaseFailure = StateError('release successful hold');
        final events = <String>[];
        Future<void Function()> prepare(String stage) async {
          if (stage == failingStage) {
            Error.throwWithStackTrace(
              prepareFailure,
              StackTrace.fromString('prepare stack'),
            );
          }
          return () {
            events.add('release $stage');
            Error.throwWithStackTrace(
              releaseFailure,
              StackTrace.fromString('release stack'),
            );
          };
        }

        await expectLater(
          prepareImageLoadingForExit(
            prepareProviders: () => prepare('providers'),
            prepareRequests: () => prepare('requests'),
          ),
          throwsA(
            isA<ImageLoadingPreparationFailure>()
                .having(
                  (error) => error.failures.map((entry) => entry.error),
                  'prepare and cleanup failures',
                  unorderedEquals([prepareFailure, releaseFailure]),
                )
                .having(
                  (error) =>
                      error.failures.map((entry) => entry.stack.toString()),
                  'original stacks',
                  unorderedEquals(['prepare stack', 'release stack']),
                ),
          ),
        );
        expect(events, [
          'release ${failingStage == 'providers' ? 'requests' : 'providers'}',
        ]);
      },
    );
  }

  test(
    'release attempts both holds, aggregates failures and remains idempotent',
    () async {
      final events = <String>[];
      final providerFailure = StateError('provider release');
      final requestFailure = StateError('request release');
      final release = await prepareImageLoadingForExit(
        prepareProviders: () async => () {
          events.add('providers');
          Error.throwWithStackTrace(
            providerFailure,
            StackTrace.fromString('provider release stack'),
          );
        },
        prepareRequests: () async => () {
          events.add('requests');
          Error.throwWithStackTrace(
            requestFailure,
            StackTrace.fromString('request release stack'),
          );
        },
      );
      expect(
        release,
        throwsA(
          isA<ImageLoadingPreparationFailure>()
              .having(
                (error) => error.failures.map((entry) => entry.error),
                'both release causes',
                [same(requestFailure), same(providerFailure)],
              )
              .having(
                (error) =>
                    error.failures.map((entry) => entry.stack.toString()),
                'original release stacks',
                ['request release stack', 'provider release stack'],
              ),
        ),
      );
      expect(events, ['requests', 'providers']);
      expect(release, returnsNormally);
      expect(events, ['requests', 'providers']);
    },
  );
}
