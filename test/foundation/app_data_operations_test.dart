import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

void main() {
  test(
    'synchronous access preserves values and releases after failure',
    () async {
      final operations = AppDataOperations();
      expect(operations.accessSync(() => 7), 7);
      expect(
        () => operations.accessSync<void>(() => throw StateError('failed')),
        throwsStateError,
      );
      expect(await operations.run(() => 8), 8);
    },
  );

  test('synchronous access cannot overtake a waiting replacement', () async {
    final operations = AppDataOperations();
    final release = Completer<void>();
    final first = operations.access(() => release.future);
    final replacement = operations.run(() => 4);
    expect(
      () => operations.accessSync(() => fail('must not start')),
      throwsA(isA<AppDataBusyException>()),
    );
    release.complete();
    await first;
    expect(await replacement, 4);
    expect(operations.accessSync(() => 5), 5);
  });

  test(
    'synchronous nested access reuses permission but publication does not',
    () async {
      final operations = AppDataOperations();
      await operations.run(() {
        expect(operations.accessSync(() => operations.accessSync(() => 6)), 6);
        operations.publish(() {
          expect(
            () => operations.accessSync(() => fail('borrowed permission')),
            throwsA(isA<AppDataBusyException>()),
          );
        });
      });
    },
  );

  test(
    'synchronous callback failure still waits for registered descendants',
    () async {
      final operations = AppDataOperations();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> child;
      expect(
        () => operations.accessSync<void>(() {
          child = operations.access(() async {
            await release.future;
            events.add('child');
          });
          throw StateError('parent');
        }),
        throwsStateError,
      );
      final replacement = operations.run(() => events.add('replacement'));
      expect(events, isEmpty);
      release.complete();
      await child;
      await replacement;
      expect(events, ['child', 'replacement']);
    },
  );

  test(
    'synchronous access seals its permission before late callbacks',
    () async {
      final operations = AppDataOperations();
      final invoke = Completer<void>();
      late Future<void> lateCall;
      operations.accessSync(() {
        lateCall = invoke.future.then((_) {
          expect(
            () => operations.accessSync(() => fail('expired permission')),
            throwsA(isA<AppDataBusyException>()),
          );
        });
      });
      final release = Completer<void>();
      final replacement = operations.run(() => release.future);
      invoke.complete();
      await lateCall;
      release.complete();
      await replacement;
    },
  );

  test(
    'accesses overlap and a waiting replacement prevents overtaking',
    () async {
      final operations = AppDataOperations();
      final releaseFirst = Completer<void>();
      final releaseSecond = Completer<void>();
      final releaseReplacement = Completer<void>();
      final replacementStarted = Completer<void>();
      final events = <String>[];
      final first = operations.access(() async {
        events.add('first');
        await releaseFirst.future;
      });
      final second = operations.access(() async {
        events.add('second');
        await releaseSecond.future;
      });
      final replacement = operations.run(() async {
        events.add('replacement');
        replacementStarted.complete();
        await releaseReplacement.future;
      });
      final later = operations.access(() => events.add('later'));
      expect(events, ['first', 'second']);
      releaseFirst.complete();
      await first;
      expect(events, ['first', 'second']);
      releaseSecond.complete();
      await replacementStarted.future;
      expect(events, ['first', 'second', 'replacement']);
      releaseReplacement.complete();
      await Future.wait([second, replacement, later]);
      expect(events, ['first', 'second', 'replacement', 'later']);
    },
  );

  test(
    'nested work retains access after its immediate parent returns',
    () async {
      final operations = AppDataOperations();
      final release = Completer<void>();
      final started = Completer<void>();
      late Future<void> child;
      final events = <String>[];
      final parent = operations.run(() {
        child = operations.access(() async {
          await operations.run(() => events.add('nested replacement'));
          started.complete();
          await release.future;
          await operations.access(() => events.add('grandchild'));
        });
        events.add('parent returned');
      });
      final later = operations.run(() => events.add('later'));
      await started.future;
      expect(events, ['nested replacement', 'parent returned']);
      release.complete();
      await Future.wait([parent, child, later]);
      expect(events, [
        'nested replacement',
        'parent returned',
        'grandchild',
        'later',
      ]);
    },
  );

  test(
    'access cannot upgrade and nested failures reach their caller',
    () async {
      final operations = AppDataOperations();
      await operations.access(() async {
        await expectLater(
          operations.run(() => fail('upgraded')),
          throwsStateError,
        );
        await expectLater(
          operations.access<void>(() => throw StateError('nested')),
          throwsStateError,
        );
        expect(await operations.access(() => 7), 7);
      });
      expect(await operations.run(() => 'released'), 'released');
    },
  );

  test('failed access releases a waiting replacement', () async {
    final operations = AppDataOperations();
    final release = Completer<void>();
    final failed = operations.access<void>(() async {
      await release.future;
      throw StateError('write');
    });
    final observed = expectLater(failed, throwsStateError);
    final later = operations.run(() => 8);
    release.complete();
    await observed;
    expect(await later, 8);
  });

  test('late callbacks cannot reuse an expired operation capability', () async {
    final operations = AppDataOperations();
    final trigger = Completer<void>();
    final entered = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];
    late Future<void> lateCallback;
    await operations.run(() {
      lateCallback = trigger.future.then((_) {
        entered.complete();
        return operations.access(() => events.add('late'));
      });
    });
    final next = operations.run(() async {
      events.add('replacement');
      await release.future;
    });
    trigger.complete();
    await entered.future;
    expect(events, ['replacement']);
    release.complete();
    await Future.wait([next, lateCallback]);
    expect(events, ['replacement', 'late']);
  });

  test('empty drain seals ownership before a late microtask', () async {
    final operations = AppDataOperations();
    final submitted = Completer<void>();
    final release = Completer<void>();
    final events = <String>[];
    late Future<void> late;
    final first = operations.run(() {
      scheduleMicrotask(
        () => scheduleMicrotask(() {
          late = operations.access(() => events.add('late'));
          submitted.complete();
        }),
      );
    });
    final replacement = operations.run(() async {
      events.add('replacement');
      await release.future;
    });
    await submitted.future;
    await first;
    expect(events, ['replacement']);
    release.complete();
    await Future.wait([replacement, late]);
    expect(events, ['replacement', 'late']);
  });

  test(
    'queued actions retain caller zones and independent capabilities',
    () async {
      final first = AppDataOperations();
      final second = AppDataOperations();
      final contextKey = Object();
      final release = Completer<void>();
      final busy = second.run(() => release.future);
      final owner = first.run(() async {
        final queued = runZoned(
          () => second.run(() async {
            expect(Zone.current[contextKey], 'caller');
            return first.access(() => 'independent');
          }),
          zoneValues: {contextKey: 'caller'},
        );
        release.complete();
        expect(await queued, 'independent');
      });
      await Future.wait([busy, owner]);
    },
  );

  test(
    'published notifications and their callbacks acquire fresh access',
    () async {
      final operations = AppDataOperations();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> notifiedReplacement;
      late Future<void> notifiedAccess;
      final owner = operations.run(() async {
        operations.publish(() {
          notifiedReplacement = operations.run(() => events.add('replacement'));
          notifiedAccess = Future<void>.value().then(
            (_) => operations.access(() => events.add('access')),
          );
        });
        await Future<void>.value();
        expect(events, isEmpty);
        await release.future;
        events.add('owner done');
      });
      release.complete();
      await owner;
      await Future.wait([notifiedReplacement, notifiedAccess]);
      expect(events, ['owner done', 'replacement', 'access']);
    },
  );

  test(
    'queued actions wait for completion and preserve submission order',
    () async {
      final operations = AppDataOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final first = operations.run(() async {
        events.add('first start');
        entered.complete();
        await release.future;
        events.add('first end');
      });
      final second = operations.run(() async {
        events.add('second');
        return 2;
      });
      await entered.future;
      expect(events, ['first start']);
      release.complete();
      await first;
      expect(await second, 2);
      expect(events, ['first start', 'first end', 'second']);
    },
  );

  test(
    'both asynchronous and synchronous failures release later actions',
    () async {
      final operations = AppDataOperations();
      final first = operations.run<void>(() async {
        throw StateError('async');
      });
      final second = operations.run<void>(() {
        throw StateError('sync');
      });
      final finalAction = operations.run(() async => 'continued');
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(await finalAction, 'continued');
    },
  );
}
