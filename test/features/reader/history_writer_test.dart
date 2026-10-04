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
    final writer = ReaderHistoryWriter(
      write: () async => asyncWrites++,
      onError: (error, stack) => fail('$error'),
    );
    writer.schedule();
    writer.dispose();
    expect(asyncWrites, 1);
    writer.dispose();
    writer.schedule();
    await tester.pump(const Duration(seconds: 2));
    expect(asyncWrites, 1);
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
        if (attempts == 2 || attempts == 4) {
          return Future.error(StateError('async failure'));
        }
        return Future.value();
      },
      onError: (error, stack) => errors.add(error),
    );
    for (var i = 0; i < 3; i++) {
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(attempts, 3);
    expect(errors, hasLength(2));
    writer.schedule();
    await expectLater(writer.dispose(), throwsA(isA<ReaderProgressFailure>()));
    await expectLater(writer.dispose(), throwsA(isA<ReaderProgressFailure>()));
    expect(errors, hasLength(3));
  });

  testWidgets('exit preserves accepted writes without issuing duplicates', (
    tester,
  ) async {
    final accepted = Completer<void>();
    var writes = 0;
    final errors = <Object>[];
    final writer = ReaderHistoryWriter(
      write: () {
        writes++;
        return accepted.future;
      },
      onError: (error, stack) => errors.add(error),
    );
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    final closing = writer.dispose();
    final failed = expectLater(closing, throwsA(isA<ReaderProgressFailure>()));
    expect(writes, 1);
    accepted.completeError(StateError('storage failure after exit'));
    await tester.pump();
    await failed;
    expect(errors, hasLength(1));
  });

  testWidgets('exit drains every accepted write and an asynchronous flush', (
    tester,
  ) async {
    final first = Completer<void>();
    final second = Completer<void>();
    final flushed = Completer<void>();
    var writes = 0;
    var closed = false;
    final writer = ReaderHistoryWriter(
      write: () => switch (++writes) {
        1 => first.future,
        2 => second.future,
        _ => flushed.future,
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
    expect(writes, 3);
    writer.schedule();
    second.complete();
    flushed.complete();
    await tester.pump(const Duration(seconds: 2));
    expect(writes, 3);
    expect(closed, isFalse);
    first.complete();
    await tester.pump();
    await closing;
    expect(closed, isTrue);
  });

  test('flush exposes new failures and a later flush retries once', () async {
    var attempts = 0;
    final writeError = StateError('storage failure');
    final errors = <Object>[];
    final writer = ReaderHistoryWriter(
      write: () async {
        attempts++;
        if (attempts < 3) throw writeError;
      },
      onError: (error, _) => errors.add(error),
    );
    writer.schedule();
    await expectLater(writer.flush(), throwsA(isA<ReaderProgressFailure>()));
    expect(attempts, 1);
    await expectLater(writer.flush(), throwsA(isA<ReaderProgressFailure>()));
    expect(attempts, 2);
    await writer.flush();
    await writer.dispose();
    expect(attempts, 3);
    expect(errors, [writeError, writeError]);
  });

  testWidgets('new delayed progress serves as the only retry', (tester) async {
    var attempts = 0;
    final writer = ReaderHistoryWriter(
      write: () async {
        attempts++;
        if (attempts <= 2) throw StateError('storage failure');
      },
      onError: (_, _) {},
    );
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    writer.schedule();
    await expectLater(writer.flush(), throwsA(isA<ReaderProgressFailure>()));
    expect(attempts, 2);
    await writer.flush();
    await writer.dispose();
    expect(attempts, 3);
  });

  for (final newerSucceedsFirst in [false, true]) {
    testWidgets(
      'new success repairs old failure; newer first=$newerSucceedsFirst',
      (tester) async {
        final oldWrite = Completer<void>();
        final newWrite = Completer<void>();
        var attempts = 0;
        final errors = <Object>[];
        final writer = ReaderHistoryWriter(
          write: () => ++attempts == 1 ? oldWrite.future : newWrite.future,
          onError: (error, _) => errors.add(error),
        );
        writer.schedule();
        await tester.pump(const Duration(seconds: 1));
        writer.schedule();
        final flushing = writer.flush();
        var finished = false;
        unawaited(flushing.then((_) => finished = true));
        if (newerSucceedsFirst) {
          newWrite.complete();
        } else {
          oldWrite.completeError(StateError('old snapshot'));
        }
        await tester.pump();
        expect(finished, isFalse);
        if (newerSucceedsFirst) {
          oldWrite.completeError(StateError('old snapshot'));
        } else {
          newWrite.complete();
        }
        await tester.pump();
        await flushing;
        await writer.dispose();
        expect(attempts, 2);
        expect(errors, hasLength(1));
      },
    );
  }

  for (final newerFailsFirst in [false, true]) {
    testWidgets(
      'old success cannot repair new failure; newer first=$newerFailsFirst',
      (tester) async {
        final oldWrite = Completer<void>();
        final newWrite = Completer<void>();
        final newerError = StateError('new snapshot');
        var attempts = 0;
        final writer = ReaderHistoryWriter(
          write: () => switch (++attempts) {
            1 => oldWrite.future,
            2 => newWrite.future,
            _ => Future.value(),
          },
          onError: (_, _) {},
        );
        writer.schedule();
        await tester.pump(const Duration(seconds: 1));
        writer.schedule();
        final flushing = writer.flush();
        final failed = expectLater(
          flushing,
          throwsA(
            isA<ReaderProgressFailure>().having(
              (failure) => failure.failures.map((entry) => entry.cause),
              'unrepaired failures',
              [newerError],
            ),
          ),
        );
        if (newerFailsFirst) {
          newWrite.completeError(newerError);
        } else {
          oldWrite.complete();
        }
        await tester.pump();
        if (newerFailsFirst) {
          oldWrite.complete();
        } else {
          newWrite.completeError(newerError);
        }
        await tester.pump();
        await failed;
        expect(attempts, 2);
        await writer.flush();
        await writer.dispose();
        expect(attempts, 3);
      },
    );
  }

  testWidgets('flush accepts and drains progress scheduled while waiting', (
    tester,
  ) async {
    final first = Completer<void>();
    final second = Completer<void>();
    final saved = <int>[];
    var page = 1;
    final writer = ReaderHistoryWriter(
      write: () {
        saved.add(page);
        return saved.length == 1 ? first.future : second.future;
      },
      onError: (_, _) {},
    );
    writer.schedule();
    final flushing = writer.flush();
    expect(identical(flushing, writer.flush()), isTrue);
    expect(saved, [1]);
    var finished = false;
    unawaited(flushing.then((_) => finished = true));
    page = 2;
    writer.schedule();
    first.complete();
    await tester.pump();
    // The new timer is submitted without waiting for its debounce deadline.
    expect(saved, [1, 2]);
    expect(finished, isFalse);
    second.complete();
    await tester.pump();
    await flushing;
    expect(finished, isTrue);
    await writer.dispose();
  });

  for (final failWrite in [false, true]) {
    testWidgets(
      'dispose joins an active flush and preserves its result; failure=$failWrite',
      (tester) async {
        final write = Completer<void>();
        var attempts = 0;
        final writer = ReaderHistoryWriter(
          write: () {
            attempts++;
            return write.future;
          },
          onError: (_, _) {},
        );
        writer.schedule();
        final flushing = writer.flush();
        final closing = writer.dispose();
        expect(identical(flushing, closing), isTrue);
        expect(identical(closing, writer.dispose()), isTrue);
        expect(identical(closing, writer.flush()), isTrue);
        writer.schedule();
        final result = expectLater(
          closing,
          failWrite ? throwsA(isA<ReaderProgressFailure>()) : completes,
        );
        if (failWrite) {
          write.completeError(StateError('final failure'));
        } else {
          write.complete();
        }
        await tester.pump(const Duration(seconds: 2));
        await result;
        expect(attempts, 1);
        expect(identical(closing, writer.dispose()), isTrue);
        expect(identical(closing, writer.flush()), isTrue);
      },
    );
  }

  testWidgets(
    'reporting failure preserves both errors and drains other writes',
    (tester) async {
      final first = Completer<void>();
      final second = Completer<void>();
      final writeError = StateError('storage failure');
      final reportingError = StateError('logging failure');
      final writeStack = StackTrace.fromString('write stack');
      final reportingStack = StackTrace.fromString('reporting stack');
      var attempts = 0;
      final writer = ReaderHistoryWriter(
        write: () => switch (++attempts) {
          1 => first.future,
          2 => second.future,
          _ => Future.value(),
        },
        onError: (_, _) =>
            Error.throwWithStackTrace(reportingError, reportingStack),
      );
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
      writer.schedule();
      final flushing = writer.flush();
      var finished = false;
      final failed = expectLater(
        flushing,
        throwsA(
          isA<ReaderProgressFailure>()
              .having(
                (failure) => failure.failures.map((entry) => entry.cause),
                'both failures',
                [writeError, reportingError],
              )
              .having(
                (failure) => failure.failures.map(
                  (entry) => entry.stackTrace.toString(),
                ),
                'original stacks',
                [writeStack.toString(), reportingStack.toString()],
              ),
        ),
      ).then((_) => finished = true);
      second.completeError(writeError, writeStack);
      await tester.pump();
      expect(finished, isFalse);
      first.complete();
      await tester.pump();
      await failed;
      await expectLater(
        writer.flush(),
        throwsA(
          isA<ReaderProgressFailure>().having(
            (failure) => failure.failures.single.reportingError,
            'reporting error survives repaired write',
            isTrue,
          ),
        ),
      );
      expect(attempts, 3);
      await expectLater(
        writer.dispose(),
        throwsA(isA<ReaderProgressFailure>()),
      );
    },
  );

  testWidgets('synchronous adapter disposal still waits for its own write', (
    tester,
  ) async {
    final accepted = Completer<void>();
    late ReaderHistoryWriter writer;
    late Future<void> closing;
    var closed = false;
    writer = ReaderHistoryWriter(
      write: () {
        closing = writer.dispose();
        unawaited(closing.then((_) => closed = true));
        return accepted.future;
      },
      onError: (_, _) {},
    );
    writer.schedule();
    await tester.pump(const Duration(seconds: 1));
    expect(closed, isFalse);
    accepted.complete();
    await tester.pump();
    await closing;
    expect(closed, isTrue);
  });

  testWidgets(
    'an accepted newer write repairs an existing failure without retry',
    (tester) async {
      final newWrite = Completer<void>();
      var attempts = 0;
      final writer = ReaderHistoryWriter(
        write: () => ++attempts == 1
            ? Future.error(StateError('old failure'))
            : newWrite.future,
        onError: (_, _) {},
      );
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
      final flushing = writer.flush();
      expect(attempts, 2);
      newWrite.complete();
      await tester.pump();
      await flushing;
      await writer.dispose();
      expect(attempts, 2);
    },
  );

  testWidgets('flush drains every failed write and retains submission order', (
    tester,
  ) async {
    final accepted = List.generate(3, (_) => Completer<void>());
    final errors = List.generate(3, (index) => StateError('failure $index'));
    var attempts = 0;
    final writer = ReaderHistoryWriter(
      write: () => attempts < accepted.length
          ? accepted[attempts++].future
          : Future.value(),
      onError: (_, _) {},
    );
    for (var index = 0; index < accepted.length; index++) {
      writer.schedule();
      await tester.pump(const Duration(seconds: 1));
    }
    var finished = false;
    final failed = expectLater(
      writer.flush(),
      throwsA(
        isA<ReaderProgressFailure>().having(
          (failure) => failure.failures.map((entry) => entry.cause),
          'submission order',
          errors,
        ),
      ),
    ).then((_) => finished = true);
    for (var index = accepted.length - 1; index >= 0; index--) {
      expect(finished, isFalse);
      accepted[index].completeError(errors[index]);
      await tester.pump();
    }
    await failed;
    expect(attempts, 3);
    await writer.flush();
    await writer.dispose();
  });
}
