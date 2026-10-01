import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/local_storage_guard.dart';
import 'package:venera_next/features/local_comics/local_import_lifecycle.dart';

void main() {
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
}
