import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/history_writer.dart';

void main() {
  testWidgets('continuous turns save the latest progress after inactivity', (
    tester,
  ) async {
    var page = 1;
    final saved = <int>[];
    final writer = ReaderHistoryWriter(
      write: () async => saved.add(page),
      flush: () => saved.add(page),
      onError: (error, stack) => fail('$error'),
    );
    writer.schedule();
    await tester.pump(const Duration(milliseconds: 800));
    page = 2;
    writer.schedule();
    await tester.pump(const Duration(milliseconds: 800));
    expect(saved, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    expect(saved, [2]);
    writer.dispose();
    expect(saved, [2]);
  });

  testWidgets('exit flushes pending progress once and cancels its timer', (
    tester,
  ) async {
    var asyncWrites = 0;
    var flushes = 0;
    final writer = ReaderHistoryWriter(
      write: () async => asyncWrites++,
      flush: () => flushes++,
      onError: (error, stack) => fail('$error'),
    );
    writer.schedule();
    writer.dispose();
    expect(flushes, 1);
    writer.dispose();
    writer.schedule();
    await tester.pump(const Duration(seconds: 2));
    expect(flushes, 1);
    expect(asyncWrites, 0);
  });

  testWidgets('save failures are reported and later turns can still save', (
    tester,
  ) async {
    var attempts = 0;
    final errors = <Object>[];
    final writer = ReaderHistoryWriter(
      write: () {
        attempts++;
        if (attempts == 1) throw StateError('sync failure');
        if (attempts == 2) return Future.error(StateError('async failure'));
        return Future.value();
      },
      flush: () => throw StateError('flush failure'),
      onError: (error, stack) => errors.add(error),
    );
    for (var i = 0; i < 3; i++) {
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(attempts, 3);
    expect(errors, hasLength(2));
    writer.schedule();
    await writer.dispose();
    await writer.dispose();
    expect(errors, hasLength(3));
  });

  testWidgets('exit preserves accepted writes without issuing duplicates', (
    tester,
  ) async {
    final accepted = Completer<void>();
    var writes = 0;
    var flushes = 0;
    final errors = <Object>[];
    final writer = ReaderHistoryWriter(
      write: () {
        writes++;
        return accepted.future;
      },
      flush: () => flushes++,
      onError: (error, stack) => errors.add(error),
    );
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    writer.dispose();
    expect(writes, 1);
    expect(flushes, 0);
    accepted.completeError(StateError('storage failure after exit'));
    await tester.pump();
    expect(errors, hasLength(1));
  });

  testWidgets('exit drains every accepted write and an asynchronous flush', (
    tester,
  ) async {
    final first = Completer<void>();
    final second = Completer<void>();
    final flushed = Completer<void>();
    var writes = 0;
    var flushes = 0;
    var closed = false;
    final writer = ReaderHistoryWriter(
      write: () => ++writes == 1 ? first.future : second.future,
      flush: () {
        flushes++;
        return flushed.future;
      },
      onError: (error, stack) => fail('$error'),
    );
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    writer.schedule();
    final closing = writer.dispose();
    unawaited(closing.then((_) => closed = true));
    expect(identical(closing, writer.dispose()), isTrue);
    expect(flushes, 1);
    writer.schedule();
    second.complete();
    flushed.complete();
    await tester.pump(const Duration(seconds: 2));
    expect(writes, 2);
    expect(closed, isFalse);
    first.complete();
    await tester.pump();
    await closing;
    expect(closed, isTrue);
  });
}
