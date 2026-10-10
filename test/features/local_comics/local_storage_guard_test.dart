import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/features/local_comics/local_import_lifecycle.dart';

void main() {
  test(
    'R2 unowned synchronous local writes cannot bypass an application snapshot',
    () async {
      final guard = LocalComicStorageGuard();
      final release = Completer<void>();
      final snapshot = AppDataOperations.instance.run(() => release.future);
      var wrote = false;
      try {
        expect(
          () => guard.write(() => wrote = true),
          throwsA(isA<AppDataBusyException>()),
        );
        expect(wrote, isFalse);
      } finally {
        release.complete();
        await snapshot;
      }
      guard.write(() => wrote = true);
      expect(wrote, isTrue);
    },
  );

  test(
    'exit drains accepted waiters and rejects newcomers until owned release',
    () async {
      final guard = LocalComicStorageGuard();
      final migrationGate = Completer<void>();
      final importGate = Completer<void>();
      final started = Completer<void>();
      final migrating = guard.runExclusive(() => migrationGate.future);
      final importing = guard.runImport(() {
        started.complete();
        return importGate.future;
      });
      final preparing = guard.prepareForExit();
      addTearDown(() async {
        if (!migrationGate.isCompleted) migrationGate.complete();
        if (!importGate.isCompleted) importGate.complete();
        await migrating;
        await importing;
        (await preparing)();
      });
      expect(identical(preparing, guard.prepareForExit()), isTrue);
      await expectLater(
        guard.runImport(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      await expectLater(
        guard.runExclusive(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      var ready = false;
      preparing.then((_) => ready = true);
      migrationGate.complete();
      await migrating;
      await started.future;
      expect(ready, isFalse);
      importGate.complete();
      await importing;
      final release = await preparing;
      release();
      final nextRelease = await guard.prepareForExit();
      release();
      await expectLater(
        guard.runImport(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      nextRelease();
      expect(await guard.runImport(() async => 'ready'), 'ready');
    },
  );

  test(
    'local exit drains failed non-PDF work and release permits retry',
    () async {
      final guard = LocalComicStorageGuard.instance;
      final gate = Completer<void>();
      final importing = guard.runImport(() async {
        await gate.future;
        throw StateError('import failed');
      });
      final failure = expectLater(importing, throwsStateError);
      final preparing = prepareLocalImportsForExit();
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await failure;
        (await preparing)();
      });
      var ready = false;
      preparing.then((_) => ready = true);
      await pumpEventQueue();
      expect(ready, isFalse);
      await expectLater(
        guard.runImport(() async {}),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      gate.complete();
      await failure;
      final release = await preparing;
      release();
      expect(await guard.runImport(() async => 'retry'), 'retry');
    },
  );
  test(
    'migration and recovery are refused while an import owns storage',
    () async {
      final guard = LocalComicStorageGuard();
      final gate = Completer<void>();
      final importing = guard.runImport(() => gate.future);
      var modified = false;
      await expectLater(
        guard.runExclusive(() async => modified = true),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      expect(modified, isFalse);
      gate.complete();
      await importing;
      await guard.runExclusive(() async => modified = true);
      expect(modified, isTrue);
    },
  );

  test('imports wait until migration or recovery finishes', () async {
    final guard = LocalComicStorageGuard();
    final gate = Completer<void>();
    var converted = false;
    final migration = guard.runExclusive(() => gate.future);
    final importing = guard.runImport(() async => converted = true);
    await Future<void>.delayed(Duration.zero);
    expect(converted, isFalse);
    await expectLater(
      guard.runExclusive(() async {}),
      throwsA(isA<LocalComicStorageBusy>()),
    );
    gate.complete();
    await migration;
    await importing;
    expect(converted, isTrue);
  });

  test('failed operations release storage and wake waiting imports', () async {
    final guard = LocalComicStorageGuard();
    final gate = Completer<void>();
    final migrating = guard.runExclusive(() async {
      await gate.future;
      throw StateError('migration failed');
    });
    final failed = expectLater(migrating, throwsStateError);
    final importing = guard.runImport(() async => 'resumed');
    gate.complete();
    await failed;
    expect(await importing, 'resumed');
    await expectLater(
      guard.runImport(() async => throw StateError('import failed')),
      throwsStateError,
    );
    expect(await guard.runExclusive(() async => 'available'), 'available');
  });

  test(
    'synchronous writes reject unrelated callers during exclusive work',
    () async {
      final guard = LocalComicStorageGuard();
      final gate = Completer<void>();
      var writes = 0;
      final exclusive = guard.runExclusive(() async {
        guard.write(() => writes++);
        await gate.future;
        guard.write(() => writes++);
      });
      expect(
        () => guard.write(() => writes++),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      gate.complete();
      await exclusive;
      expect(writes, 2);
      guard.write(() => writes++);
      expect(writes, 3);
    },
  );

  test(
    'accepted import writes drain during exit while new writes fail',
    () async {
      final guard = LocalComicStorageGuard();
      final gate = Completer<void>();
      var writes = 0;
      final importing = guard.runImport(() async {
        await gate.future;
        guard.write(() => writes++);
      });
      final preparing = guard.prepareForExit();
      expect(
        () => guard.write(() => writes++),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      gate.complete();
      await importing;
      final release = await preparing;
      expect(writes, 1);
      expect(
        () => guard.write(() => writes++),
        throwsA(isA<LocalComicStorageBusy>()),
      );
      release();
      guard.write(() => writes++);
      expect(writes, 2);
    },
  );

  for (final exclusive in [false, true]) {
    test(
      'expired ${exclusive ? "exclusive" : "import"} owner cannot write later',
      () async {
        final guard = LocalComicStorageGuard();
        late void Function() lateWrite;
        Future<void> action() async {
          lateWrite = Zone.current.bindCallback(() => guard.write(() {}));
        }

        if (exclusive) {
          await guard.runExclusive(action);
        } else {
          await guard.runImport(action);
        }
        expect(lateWrite, throwsA(isA<LocalComicStorageBusy>()));
        expect(
          await guard.runExclusive(() async => guard.write(() => 'ok')),
          'ok',
        );
      },
    );
  }
}
