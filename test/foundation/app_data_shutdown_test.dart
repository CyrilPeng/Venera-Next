import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

void main() {
  test(
    'terminal admission joins queued owners and nested writes before final persistence',
    () async {
      final operations = AppDataOperations();
      final release = Completer<void>();
      final childRelease = Completer<void>();
      final events = <String>[];
      late Future<void> child;
      final first = operations.access(() async {
        await release.future;
        child = operations.access(() async {
          await childRelease.future;
          events.add('child');
        });
      });
      final replacement = operations.run(() => events.add('replacement'));
      final closing = operations.closeAndWait(
        finalize: () async {
          await operations.access(() => events.add('final persistence'));
        },
      );
      expect(operations.isClosing, isTrue);
      expect(identical(closing, operations.closeAndWait()), isTrue);
      await expectLater(
        operations.access(() => fail('late read')),
        throwsA(isA<AppDataClosedException>()),
      );
      await expectLater(
        operations.prepare(() => fail('late prepare')),
        throwsA(isA<AppDataClosedException>()),
      );
      expect(
        () => operations.accessSync(() => 1),
        throwsA(isA<AppDataClosedException>()),
      );
      release.complete();
      await pumpEventQueue();
      expect(events, isEmpty);
      childRelease.complete();
      await Future.wait([first, child, replacement, closing]);
      expect(events, ['child', 'replacement', 'final persistence']);
      await expectLater(
        operations.run(() => fail('late import')),
        throwsA(isA<AppDataClosedException>()),
      );
    },
  );

  test(
    'native callbacks can finish an accepted preparation while new preparations are rejected',
    () async {
      final operations = AppDataOperations();
      final native = Completer<void>();
      final entered = Completer<void>();
      final preparing = operations.prepare(() async {
        entered.complete();
        await native.future;
        await operations.access(() {});
      });
      await entered.future;
      var closed = false;
      final closing = operations.closeAndWait().then((_) => closed = true);
      await expectLater(
        operations.prepare(() {}),
        throwsA(isA<AppDataClosedException>()),
      );
      // Deliberately outside the preparation's Dart zone, as native JS callbacks are.
      await operations.access(() => native.complete());
      await Future.wait([preparing, closing]);
      expect(closed, isTrue);
      await expectLater(
        operations.access(() {}),
        throwsA(isA<AppDataClosedException>()),
      );
    },
  );

  test(
    'final save retries the original finalizer without reopening ordinary admission',
    () async {
      final operations = AppDataOperations();
      var attempts = 0;
      final failure = StateError('save');
      final first = operations.closeAndWait(
        finalize: () async {
          attempts++;
          await operations.access(() {});
          if (attempts == 1) throw failure;
        },
      );
      await expectLater(first, throwsA(same(failure)));
      expect(operations.isClosing, isTrue);
      await expectLater(
        operations.access(() {}),
        throwsA(isA<AppDataClosedException>()),
      );
      final retry = operations.closeAndWait(
        finalize: () => fail('replaced finalizer'),
      );
      await retry;
      expect(attempts, 2);
      expect(identical(retry, operations.closeAndWait()), isTrue);
    },
  );

  test(
    'final persistence cannot lend admission to notifications or late descendants',
    () async {
      final operations = AppDataOperations();
      late Future<void> Function() lateAccess;
      await operations.closeAndWait(
        finalize: () async {
          lateAccess = Zone.current.bindCallback(
            () => operations.access(() {}),
          );
          operations.publish(() {
            expect(
              () => operations.accessSync(() {}),
              throwsA(isA<AppDataClosedException>()),
            );
          });
        },
      );
      await expectLater(lateAccess(), throwsA(isA<AppDataClosedException>()));
    },
  );

  test(
    'closing from an admitted operation rejects without sealing the owner',
    () async {
      final operations = AppDataOperations();
      await operations.access(() async {
        await expectLater(operations.closeAndWait(), throwsStateError);
      });
      expect(operations.isClosing, isFalse);
      expect(await operations.access(() => 42), 42);
      await operations.closeAndWait();
    },
  );
}
