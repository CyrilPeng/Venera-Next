import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

PersistenceFailure persistenceFailure(PersistenceCommitState state) =>
    PersistenceFailure(
      commitState: state,
      cause: StateError('duration write failed'),
      stackTrace: StackTrace.current,
    );

void main() {
  test(
    'reading session records checkpoints and excludes paused time',
    () async {
      var elapsed = Duration.zero;
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          recorded.add(duration);
        },
      );

      tracker.start();
      elapsed = const Duration(seconds: 45);
      await tracker.checkpoint();
      elapsed = const Duration(minutes: 1);
      await tracker.pause();

      elapsed = const Duration(minutes: 10);
      tracker.start();
      elapsed = const Duration(minutes: 10, seconds: 30);
      await tracker.dispose();

      expect(recorded, const [
        Duration(seconds: 45),
        Duration(seconds: 15),
        Duration(seconds: 30),
      ]);
    },
  );

  test('reading session start and dispose are idempotent', () async {
    var elapsed = Duration.zero;
    final recorded = <Duration>[];
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (duration) async {
        recorded.add(duration);
      },
    );

    tracker.start();
    tracker.start();
    elapsed = const Duration(seconds: 20);
    await tracker.dispose();
    elapsed = const Duration(seconds: 40);
    tracker.start();
    await tracker.dispose();

    expect(recorded, const [Duration(seconds: 20)]);
    expect(tracker.isRunning, isFalse);
  });

  test(
    'flush retries only the uncommitted period and removes its error',
    () async {
      var elapsed = Duration.zero;
      final attempts = <Duration>[];
      final reported = <Object>[];
      final failure = persistenceFailure(PersistenceCommitState.notCommitted);
      var committed = Duration.zero;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          attempts.add(duration);
          if (attempts.length == 1) throw failure;
          committed += duration;
        },
        onError: (error, _) => reported.add(error),
      );

      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.checkpoint();
      elapsed = const Duration(seconds: 30);
      await tracker.pause();
      await tracker.flush();
      await tracker.dispose();

      expect(attempts, const [
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 10),
      ]);
      expect(committed, const Duration(seconds: 30));
      expect(reported, [same(failure)]);
    },
  );

  for (final state in [
    PersistenceCommitState.committed,
    PersistenceCommitState.unknown,
    null,
  ]) {
    test('flush never replays a period with commit state $state', () async {
      var elapsed = Duration.zero;
      var writes = 0;
      final Object error = state == null
          ? StateError('unclassified write failure')
          : persistenceFailure(state);
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (_) async {
          writes++;
          throw error;
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.pause();

      final matchesFailure = isA<ReadingDurationFailure>().having(
        (failure) => failure.failures.single.cause,
        'original cause',
        same(error),
      );
      await expectLater(tracker.flush(), throwsA(matchesFailure));
      await expectLater(tracker.flush(), throwsA(matchesFailure));
      await expectLater(tracker.dispose(), throwsA(matchesFailure));
      expect(writes, 1);
    });
  }

  test('flush retries a failed period at most once per call', () async {
    var elapsed = Duration.zero;
    final errors = <Object>[];
    final stacks = <StackTrace>[];
    var attempts = 0;
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (_) async {
        attempts++;
        if (attempts <= 2) {
          final error = persistenceFailure(PersistenceCommitState.notCommitted);
          final stack = StackTrace.current;
          errors.add(error);
          stacks.add(stack);
          Error.throwWithStackTrace(error, stack);
        }
      },
    );
    tracker.start();
    elapsed = const Duration(seconds: 10);
    await tracker.pause();

    await expectLater(
      tracker.flush(),
      throwsA(
        isA<ReadingDurationFailure>()
            .having(
              (failure) => failure.failures.map((entry) => entry.cause),
              'every failed attempt',
              errors,
            )
            .having(
              (failure) => failure.failures.map((entry) => entry.stackTrace),
              'original stacks',
              stacks,
            )
            .having(
              (failure) => failure.failures.map((entry) => entry.duration),
              'reading period',
              const [Duration(seconds: 10), Duration(seconds: 10)],
            ),
      ),
    );
    expect(attempts, 2);
    await tracker.flush();
    await tracker.dispose();
    expect(attempts, 3);
  });

  test('a retry with an unknown outcome is never retried again', () async {
    var elapsed = Duration.zero;
    var attempts = 0;
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (_) async {
        attempts++;
        throw persistenceFailure(
          attempts == 1
              ? PersistenceCommitState.notCommitted
              : PersistenceCommitState.unknown,
        );
      },
    );
    tracker.start();
    elapsed = const Duration(seconds: 10);
    await tracker.pause();
    await expectLater(tracker.flush(), throwsA(isA<ReadingDurationFailure>()));
    await expectLater(tracker.flush(), throwsA(isA<ReadingDurationFailure>()));
    await expectLater(
      tracker.dispose(),
      throwsA(isA<ReadingDurationFailure>()),
    );
    expect(attempts, 2);
  });

  test(
    'several failed periods do not prevent later writes or retries',
    () async {
      var elapsed = Duration.zero;
      final attempts = <Duration>[];
      var failing = true;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          attempts.add(duration);
          if (failing && duration.inSeconds <= 20) {
            throw persistenceFailure(PersistenceCommitState.notCommitted);
          }
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      final first = tracker.checkpoint();
      elapsed = const Duration(seconds: 30);
      final second = tracker.checkpoint();
      elapsed = const Duration(seconds: 60);
      await tracker.pause();
      await Future.wait([first, second]);
      failing = false;
      await tracker.flush();
      await tracker.dispose();
      expect(attempts, const [
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 30),
        Duration(seconds: 10),
        Duration(seconds: 20),
      ]);
    },
  );

  test(
    'reporting errors stay observable after their write is repaired',
    () async {
      var elapsed = Duration.zero;
      final reportingError = StateError('reporting failed');
      final reportingStack = StackTrace.current;
      final written = <Duration>[];
      var attempts = 0;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          attempts++;
          if (attempts == 1) {
            throw persistenceFailure(PersistenceCommitState.notCommitted);
          }
          written.add(duration);
        },
        onError: (_, _) =>
            Error.throwWithStackTrace(reportingError, reportingStack),
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.checkpoint();
      elapsed = const Duration(seconds: 30);
      await tracker.pause();
      final matchesReportingError = isA<ReadingDurationFailure>()
          .having(
            (failure) => failure.failures,
            'only reporting error',
            hasLength(1),
          )
          .having(
            (failure) => failure.failures.single.cause,
            'reporting cause',
            same(reportingError),
          )
          .having(
            (failure) => failure.failures.single.stackTrace,
            'reporting stack',
            same(reportingStack),
          )
          .having(
            (failure) => failure.failures.single.reportingError,
            'reporting failure',
            isTrue,
          );
      await expectLater(tracker.flush(), throwsA(matchesReportingError));
      await expectLater(tracker.dispose(), throwsA(matchesReportingError));
      expect(written, const [Duration(seconds: 20), Duration(seconds: 10)]);
      expect(attempts, 3);
    },
  );

  test(
    'flush shares its drain and serializes periods arriving during retry',
    () async {
      var elapsed = Duration.zero;
      final retryStarted = Completer<void>();
      final releaseRetry = Completer<void>();
      final finalWriteStarted = Completer<void>();
      final releaseFinalWrite = Completer<void>();
      final attempts = <Duration>[];
      var writers = 0;
      var maximumWriters = 0;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          writers++;
          if (writers > maximumWriters) maximumWriters = writers;
          attempts.add(duration);
          try {
            if (attempts.length == 1) {
              throw persistenceFailure(PersistenceCommitState.notCommitted);
            }
            if (attempts.length == 2) {
              retryStarted.complete();
              await releaseRetry.future;
            } else {
              finalWriteStarted.complete();
              await releaseFinalWrite.future;
            }
          } finally {
            writers--;
          }
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.checkpoint();
      final flushing = tracker.flush();
      expect(tracker.flush(), same(flushing));
      var flushed = false;
      unawaited(flushing.then((_) => flushed = true));
      await retryStarted.future;
      elapsed = const Duration(seconds: 30);
      final paused = tracker.pause();
      releaseRetry.complete();
      await finalWriteStarted.future;
      expect(flushed, isFalse);
      expect(tracker.flush(), same(flushing));
      releaseFinalWrite.complete();
      await Future.wait([flushing, paused]);
      await tracker.dispose();

      expect(maximumWriters, 1);
      expect(attempts, const [
        Duration(seconds: 10),
        Duration(seconds: 10),
        Duration(seconds: 20),
      ]);
    },
  );

  test(
    'dispose freezes the clock and shares pending final-write failure',
    () async {
      var elapsed = Duration.zero;
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      final failure = StateError('unknown duration result');
      final attempts = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          attempts.add(duration);
          writeStarted.complete();
          await releaseWrite.future;
          throw failure;
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      final closing = tracker.dispose();
      expect(tracker.dispose(), same(closing));
      expect(tracker.isRunning, isFalse);
      final observed = expectLater(
        closing,
        throwsA(isA<ReadingDurationFailure>()),
      );
      var finished = false;
      unawaited(observed.then((_) => finished = true));
      await writeStarted.future;
      elapsed = const Duration(seconds: 30);
      tracker.start();
      expect(tracker.isRunning, isFalse);
      expect(finished, isFalse);
      releaseWrite.complete();
      await observed;
      expect(tracker.dispose(), same(closing));
      await expectLater(
        tracker.dispose(),
        throwsA(isA<ReadingDurationFailure>()),
      );
      expect(attempts, const [Duration(seconds: 10)]);
    },
  );
}
