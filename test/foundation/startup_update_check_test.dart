import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/startup_update_check.dart';

void main() {
  test(
    'closing waits accepted persistence and starts no later checks',
    () async {
      final reserved = Completer<bool>();
      var sources = 0;
      var applications = 0;
      final check = StartupUpdateCheck(
        reserveCheck: () => reserved.future,
        checkSources: () async {
          sources++;
        },
        checkApplication: (_) async {
          applications++;
        },
        applicationCheckEnabled: () => true,
      );
      final started = check.start();
      expect(identical(started, check.start()), isTrue);
      var closed = false;
      final closing = check.closeAndWait().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      reserved.complete(true);
      await Future.wait([started, closing]);
      expect(sources, 0);
      expect(applications, 0);
    },
  );

  test(
    'shared source check keeps its owner while retired startup cannot continue',
    () async {
      final sourceEntered = Completer<void>();
      final sourceDone = Completer<void>();
      var versions = 0;
      final check = StartupUpdateCheck(
        reserveCheck: () async => true,
        checkSources: () {
          sourceEntered.complete();
          return sourceDone.future;
        },
        checkApplication: (_) async {
          versions++;
        },
        applicationCheckEnabled: () => true,
      );
      final started = check.start();
      await sourceEntered.future;
      await check.closeAndWait();
      expect(sourceDone.isCompleted, isFalse);
      sourceDone.complete();
      await started;
      await pumpEventQueue();
      expect(versions, 0);
    },
  );

  test('application request actually drains after its cancellation', () async {
    final entered = Completer<void>();
    final released = Completer<void>();
    final check = StartupUpdateCheck(
      reserveCheck: () async => true,
      checkSources: () async {},
      checkApplication: (scope) async {
        entered.complete();
        await scope.whenCancelled;
        await released.future;
      },
      applicationCheckEnabled: () => true,
    );
    final started = check.start();
    await entered.future;
    var closed = false;
    final closing = check.closeAndWait().then((_) => closed = true);
    await pumpEventQueue();
    expect(closed, isFalse);
    released.complete();
    await Future.wait([started, closing]);
  });

  test(
    'reservation and setting preserve the source-before-application sequence',
    () async {
      for (final reserved in [false, true]) {
        for (final enabled in [false, true]) {
          final events = <String>[];
          final check = StartupUpdateCheck(
            reserveCheck: () async {
              events.add('reserve');
              return reserved;
            },
            checkSources: () async {
              events.add('sources');
            },
            checkApplication: (_) async {
              events.add('version');
            },
            applicationCheckEnabled: () => enabled,
          );
          await check.start();
          expect(events, [
            'reserve',
            if (reserved) 'sources',
            if (reserved && enabled) 'version',
          ]);
          await check.closeAndWait();
        }
      }
    },
  );

  test(
    'persistence failure is reported but close still joins the completed task',
    () async {
      final failure = StateError('save failed');
      final check = StartupUpdateCheck(
        reserveCheck: () async => throw failure,
        checkSources: () async => fail('no source check'),
        checkApplication: (_) async => fail('no version check'),
        applicationCheckEnabled: () => true,
      );
      await expectLater(check.start(), throwsA(same(failure)));
      await check.closeAndWait();
    },
  );
}
