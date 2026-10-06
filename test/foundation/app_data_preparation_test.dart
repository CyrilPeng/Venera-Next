import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

void main() {
  test(
    'preparation admits native accesses before a queued replacement',
    () async {
      final operations = AppDataOperations();
      final releasePreparation = Completer<void>();
      final releaseAccess = Completer<void>();
      final releaseReplacement = Completer<void>();
      final enteredReplacement = Completer<void>();
      final events = <String>[];
      final preparing = operations.prepare(() async {
        events.add('prepare');
        await releasePreparation.future;
      });
      final replacement = operations.run(() async {
        events.add('replace');
        enteredReplacement.complete();
        await releaseReplacement.future;
      });
      final second = operations.prepare(() => events.add('second prepare'));
      // Neither of these callbacks inherits the initiating preparation's Zone.
      expect(operations.accessSync(() => 3), 3);
      final access = operations.access(() async {
        events.add('access');
        await releaseAccess.future;
      });
      expect(events, ['prepare', 'access']);
      releasePreparation.complete();
      await preparing;
      expect(events, ['prepare', 'access']);
      expect(
        () => operations.accessSync(() => 4),
        throwsA(isA<AppDataBusyException>()),
      );
      releaseAccess.complete();
      await enteredReplacement.future;
      expect(events, ['prepare', 'access', 'replace']);
      releaseReplacement.complete();
      await Future.wait([access, replacement, second]);
      expect(events, ['prepare', 'access', 'replace', 'second prepare']);
    },
  );

  test('a waiting replacement still precedes later preparations', () async {
    final operations = AppDataOperations();
    final release = Completer<void>();
    final events = <String>[];
    final access = operations.access(() => release.future);
    final replacement = operations.run(() => events.add('replace'));
    final preparing = operations.prepare(() => events.add('prepare'));
    final later = operations.access(() => events.add('access'));
    expect(events, isEmpty);
    release.complete();
    await Future.wait([access, replacement, preparing, later]);
    expect(events, ['replace', 'prepare', 'access']);
  });

  test('preparation does not wait for earlier ordinary access', () async {
    final operations = AppDataOperations();
    final release = Completer<void>();
    final access = operations.access(() => release.future);
    expect(await operations.prepare(() => 5), 5);
    release.complete();
    await access;
  });

  test(
    'nested preparation drains real descendants after parent failure',
    () async {
      final operations = AppDataOperations();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> child;
      final parent = operations.prepare<void>(() {
        child = operations.prepare(() async {
          await release.future;
          await operations.prepare(() => events.add('grandchild'));
          throw StateError('child');
        });
        throw StateError('parent');
      });
      final observedParent = expectLater(parent, throwsStateError);
      final observedChild = expectLater(child, throwsStateError);
      final replacement = operations.run(() => events.add('replace'));
      expect(events, isEmpty);
      release.complete();
      await Future.wait([observedParent, observedChild, replacement]);
      expect(events, ['grandchild', 'replace']);
    },
  );

  test(
    'access and preparation cannot upgrade; exclusive can nest either',
    () async {
      final operations = AppDataOperations();
      await operations.access(() async {
        await expectLater(
          operations.prepare(() => fail('upgraded')),
          throwsStateError,
        );
      });
      await operations.prepare(() async {
        await expectLater(
          operations.run(() => fail('upgraded')),
          throwsStateError,
        );
        await operations.access(() async {
          await expectLater(
            operations.prepare(() => fail('upgraded')),
            throwsStateError,
          );
        });
      });
      expect(
        await operations.run(
          () => operations.prepare(
            () => operations.run(() => operations.accessSync(() => 6)),
          ),
        ),
        6,
      );
    },
  );

  test(
    'publication clears both capabilities and retains independent caller zone',
    () async {
      final operations = AppDataOperations();
      final contextKey = Object();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> listener;
      late Object owner;
      final parent = operations.prepare(() async {
        owner = operations.sharingScope!;
        await operations.access(() {
          expect(operations.sharingScope, isNot(same(owner)));
          operations.publish(() {
            expect(operations.sharingScope, isNull);
            listener = runZoned(
              () => operations.prepare(() {
                expect(Zone.current[contextKey], 'listener');
                expect(operations.sharingScope, isNot(same(owner)));
                events.add('listener');
              }),
              zoneValues: {contextKey: 'listener'},
            );
          });
        });
        await release.future;
        events.add('parent');
      });
      await pumpEventQueue();
      expect(events, isEmpty);
      release.complete();
      await parent;
      await listener;
      expect(events, ['parent', 'listener']);
      expect(operations.sharingScope, isNull);
    },
  );

  test(
    'expired preparation cannot bypass the next exclusive operation',
    () async {
      final operations = AppDataOperations();
      final invoke = Completer<void>();
      final invoked = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> late;
      await operations.prepare(() {
        late = invoke.future.then((_) {
          expect(operations.sharingScope, isNull);
          final result = operations.prepare(() => events.add('late'));
          invoked.complete();
          return result;
        });
      });
      final replacement = operations.run(() async {
        events.add('replace');
        await release.future;
      });
      invoke.complete();
      await invoked.future;
      expect(events, ['replace']);
      release.complete();
      await Future.wait([late, replacement]);
      expect(events, ['replace', 'late']);
    },
  );

  test(
    'empty preparation drain seals before late microtask admission',
    () async {
      final operations = AppDataOperations();
      final invoked = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      late Future<void> late;
      final first = operations.prepare(() {
        scheduleMicrotask(
          () => scheduleMicrotask(() {
            late = operations.prepare(() => events.add('late'));
            invoked.complete();
          }),
        );
      });
      final replacement = operations.run(() async {
        events.add('replace');
        await release.future;
      });
      await invoked.future;
      await first;
      expect(events, ['replace']);
      release.complete();
      await Future.wait([late, replacement]);
      expect(events, ['replace', 'late']);
    },
  );
}
