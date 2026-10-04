import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/reading_session.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

void main() {
  test(
    'image and auto resume failures still release the session and restart its clock',
    () async {
      final images = ImageWork();
      final imageError = StateError('image resume');
      final autoError = StateError('auto resume');
      final imageStack = StackTrace.fromString('image resume original stack');
      final autoStack = StackTrace.fromString('auto resume original stack');
      var elapsed = Duration.zero;
      final durations = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async => durations.add(duration),
      );
      var autoCalls = 0;
      final session = ReaderSession(
        imageWork: images,
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (paused) {
          autoCalls++;
          if (!paused) Error.throwWithStackTrace(autoError, autoStack);
        },
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 5);
      final release = session.holdForExit();
      images.addResumeListener(
        () => Error.throwWithStackTrace(imageError, imageStack),
      );
      expect(
        release,
        throwsA(
          isA<ReaderSessionFailure>().having(
            (error) => _sessionCauses(error).toList(),
            'all recovery errors',
            [same(imageError), same(autoError)],
          ),
        ),
      );
      expect(session.isHeld, isFalse);
      expect(tracker.isRunning, isTrue);
      final callsAfterRelease = autoCalls;
      release();
      expect(autoCalls, callsAfterRelease);
      final task = images.start();
      expect(task, isNotNull);
      task!.finish();
      elapsed = const Duration(seconds: 8);
      await session.dispose();
      expect(durations, [
        const Duration(seconds: 5),
        const Duration(seconds: 3),
      ]);
    },
  );

  test(
    'failed session preparation retains image drain and all restoration errors',
    () async {
      final images = ImageWork();
      final readError = StateError('image read');
      final imageResumeError = StateError('image resume');
      final autoResumeError = StateError('auto resume');
      final task = images.start()!;
      task.recordFailure(readError, StackTrace.current);
      task.finish();
      final tracker = ReadingSessionTracker(onDuration: (_) async {});
      final session = ReaderSession(
        imageWork: images,
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (paused) {
          if (!paused) throw autoResumeError;
        },
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      images.addResumeListener(() => throw imageResumeError);
      final failure = await _sessionFailure(session.prepareForExit());
      expect(_sessionCauses(failure), [
        same(readError),
        same(imageResumeError),
        same(autoResumeError),
      ]);
      expect(session.isHeld, isFalse);
      expect(tracker.isRunning, isTrue);
      await session.dispose();
    },
  );

  test(
    'a failed initial pause retains image and auto restoration failures',
    () async {
      final images = ImageWork();
      final pauseError = StateError('pause');
      final imageError = StateError('image resume');
      final autoError = StateError('auto resume');
      final tracker = ReadingSessionTracker(onDuration: (_) async {});
      final session = ReaderSession(
        imageWork: images,
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (paused) => throw paused ? pauseError : autoError,
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      images.addResumeListener(() => throw imageError);
      expect(
        session.holdForExit,
        throwsA(
          isA<ReaderSessionFailure>().having(
            (error) => _sessionCauses(error).toList(),
            'initial and restoration errors',
            [same(pauseError), same(imageError), same(autoError)],
          ),
        ),
      );
      expect(session.isHeld, isFalse);
      expect(tracker.isRunning, isTrue);
      await session.dispose();
    },
  );

  test(
    'a synchronous resumed image starts a fresh preparation without a progress revision',
    () async {
      final images = ImageWork();
      final source = Completer<void>();
      ImageWorkTask? resumedTask;
      Future<void>? reading;
      final session = ReaderSession(
        imageWork: images,
        durations: ReadingSessionTracker(onDuration: (_) async {}),
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (_) {},
        onClosed: () {},
        foreground: false,
      );
      final unsubscribe = images.addResumeListener(() {
        expect(session.isHeld, isFalse);
        final task = resumedTask = images.start()!;
        reading = () async {
          try {
            await task.read(() => source.future);
          } on ImageWorkTaskCancelled {
            // The accepted original read still owns its completion.
          } finally {
            task.finish();
          }
        }();
      });
      final first = session.prepareForExit();
      final releaseFirst = await first;
      expect(session.prepareForExit(), same(first));
      releaseFirst();
      expect(resumedTask, isNotNull);
      unsubscribe();
      var preparedAgain = false;
      final second = session.prepareForExit();
      expect(second, isNot(same(first)));
      final preparing = second.then((release) {
        preparedAgain = true;
        return release;
      });
      await pumpEventQueue();
      expect(preparedAgain, isFalse);
      expect(resumedTask!.isCancelled, isTrue);
      source.complete();
      await reading;
      final releaseSecond = await preparing;
      releaseSecond();
      await session.dispose();
    },
  );

  for (final lateRevision in [false, true]) {
    test(
      'dispose retains consumed image failures while preparation saves; late revision=$lateRevision',
      () async {
        final images = ImageWork();
        final task = images.start()!;
        final saving = Completer<void>();
        final imageError = StateError('image read failed');
        final imageStack = StackTrace.current;
        final saveError = StateError('progress disk failure');
        final session = ReaderSession(
          imageWork: images,
          durations: ReadingSessionTracker(onDuration: (_) async {}),
          progress: ReaderHistoryWriter(
            write: () async {
              await saving.future;
              throw saveError;
            },
            onError: (_, _) {},
          ),
          pauseAutoReading: (_) {},
          onClosed: () {},
          foreground: false,
        );
        session.scheduleProgress();
        final preparing = _sessionFailure(session.prepareForExit());
        task.recordFailure(imageError, imageStack);
        task.finish();
        await pumpEventQueue();

        // The original image drain has consumed the error, while the reader's
        // preparation still owns it and waits for the actual progress write.
        final releaseProbe = await images.prepareForExit();
        releaseProbe();
        if (lateRevision) session.scheduleProgress();
        final closing = session.dispose();
        expect(session.dispose(), same(closing));
        final closed = _sessionFailure(closing);
        saving.complete();
        final preparedFailure = await preparing;
        final closedFailure = await closed;

        for (final failure in [preparedFailure, closedFailure]) {
          expect(
            failure.failures.map((entry) => entry.operation),
            unorderedEquals(['image operations', 'progress']),
          );
          final imageFailure = failure.failures.singleWhere(
            (entry) => entry.operation == 'image operations',
          );
          final original =
              (imageFailure.error as ImageWorkFailure).failures.single;
          expect(original.error, same(imageError));
          expect(original.stack, same(imageStack));
          final saveFailure = failure.failures.singleWhere(
            (entry) => entry.operation == 'progress',
          );
          expect(
            (saveFailure.error as ReaderProgressFailure).cause,
            same(saveError),
          );
        }
        final preparedImage = preparedFailure.failures.singleWhere(
          (entry) => entry.operation == 'image operations',
        );
        final closedImage = closedFailure.failures.singleWhere(
          (entry) => entry.operation == 'image operations',
        );
        expect(closedImage.error, same(preparedImage.error));
        expect(closedImage.stackTrace, same(preparedImage.stackTrace));
        await expectLater(session.dispose(), throwsA(same(closedFailure)));
      },
    );
  }

  test(
    'dispose freezes duration while joining a cancelled original read',
    () async {
      var elapsed = Duration.zero;
      final durations = <Duration>[];
      final images = ImageWork();
      final rawRead = Completer<void>();
      final task = images.start()!;
      final reading = () async {
        try {
          await task.read(() => rawRead.future);
        } on ImageWorkTaskCancelled {
          // Cancellation becomes observable only after the original read ends.
        } finally {
          task.finish();
        }
      }();
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async => durations.add(duration),
      );
      var notifications = 0;
      final session = ReaderSession(
        imageWork: images,
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (_) {},
        onClosed: () => notifications++,
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      final closing = session.dispose();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      expect(tracker.isRunning, isFalse);
      expect(task.isCancelled, isTrue);
      expect(images.start(), isNull);
      elapsed = const Duration(minutes: 10);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(notifications, 0);
      rawRead.complete();
      await reading;
      await closing;
      expect(durations, const [Duration(seconds: 10)]);
      expect(notifications, 1);
      expect(images.start(), isNull);
    },
  );

  test(
    'image and save failures retain diagnostics and independent exit holds',
    () async {
      final images = ImageWork();
      final originalRead = Completer<void>();
      final imageFailure = StateError('read failed after cancellation');
      final progressFailure = StateError('progress failed');
      final task = images.start()!;
      final reading = () async {
        try {
          await task.read(() => originalRead.future);
        } catch (error, stack) {
          task.recordFailure(error, stack);
        } finally {
          task.finish();
        }
      }();
      var writes = 0;
      final session = ReaderSession(
        imageWork: images,
        durations: ReadingSessionTracker(onDuration: (_) async {}),
        progress: ReaderHistoryWriter(
          write: () async {
            if (++writes == 1) throw progressFailure;
          },
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () {},
        foreground: false,
      );
      session.scheduleProgress();
      final releaseHost = session.holdForExit();
      expect(task.isCancelled, isTrue);
      final preparation = session.prepareForExit();
      final observed = expectLater(
        preparation,
        throwsA(
          isA<ReaderSessionFailure>()
              .having(
                (failure) => failure.failures.map((entry) => entry.operation),
                'operations',
                unorderedEquals(['image operations', 'progress']),
              )
              .having(
                (failure) =>
                    (failure.failures
                                .singleWhere(
                                  (entry) =>
                                      entry.operation == 'image operations',
                                )
                                .error
                            as ImageWorkFailure)
                        .failures
                        .single
                        .error,
                'original image failure',
                same(imageFailure),
              )
              .having(
                (failure) =>
                    (failure.failures
                                .singleWhere(
                                  (entry) => entry.operation == 'progress',
                                )
                                .error
                            as ReaderProgressFailure)
                        .cause,
                'original progress failure',
                same(progressFailure),
              ),
        ),
      );
      originalRead.completeError(imageFailure);
      await reading;
      await observed;
      expect(session.isHeld, isTrue);
      expect(images.start(), isNull);
      releaseHost();
      expect(session.isHeld, isFalse);
      final newTask = images.start();
      expect(newTask, isNotNull);
      newTask!.finish();
      final releaseRetry = await session.prepareForExit();
      expect(writes, 2);
      expect(images.start(), isNull);
      releaseRetry();
      await session.dispose();
    },
  );

  test(
    'duration requires foreground and ready content independently',
    () async {
      var elapsed = Duration.zero;
      final writes = <Duration>[];
      final paused = <bool>[];
      var flushes = 0;
      var closed = 0;
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          onDuration: (duration) async => writes.add(duration),
        ),
        progress: ReaderHistoryWriter(
          write: () async => flushes++,
          onError: (error, stack) => fail('$error'),
        ),
        pauseAutoReading: paused.add,
        onClosed: () => closed++,
        foreground: false,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      session.setForeground(true);
      session.setContentReady(true);
      elapsed = const Duration(seconds: 20);
      session.setContentReady(false);
      elapsed = const Duration(seconds: 30);
      session.setForeground(false);
      elapsed = const Duration(seconds: 40);
      session.setContentReady(true);
      elapsed = const Duration(seconds: 50);
      session.setForeground(true);
      elapsed = const Duration(seconds: 65);
      session.scheduleProgress();
      final closing = session.dispose();
      expect(flushes, 1);
      expect(session.contentReady, isFalse);
      await closing;
      expect(writes, [
        const Duration(seconds: 10),
        const Duration(seconds: 15),
      ]);
      expect(paused, [false, true, false]);
      expect(closed, 1);
    },
  );

  test(
    'close drains duration writes once and rejects late lifecycle events',
    () async {
      var elapsed = Duration.zero;
      final accepted = Completer<void>();
      final events = <String>[];
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          onDuration: (duration) {
            events.add('duration');
            return accepted.future;
          },
        ),
        progress: ReaderHistoryWriter(
          write: () async => events.add('flush'),
          onError: (error, stack) => fail('$error'),
        ),
        pauseAutoReading: (_) => events.add('pause'),
        onClosed: () => events.add('closed'),
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      session.scheduleProgress();
      final closing = session.dispose();
      expect(identical(closing, session.dispose()), isTrue);
      expect(events, ['flush']);
      session.setForeground(false);
      session.setContentReady(true);
      session.scheduleProgress();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['flush', 'duration']);
      expect(session.contentReady, isFalse);
      accepted.complete();
      await closing;
      expect(events, ['flush', 'duration', 'closed']);
    },
  );

  test(
    'failed duration and progress writes remain observable after closing',
    () async {
      var elapsed = Duration.zero;
      final errors = <String>[];
      var closed = 0;
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          onDuration: (_) async => throw StateError('duration'),
          onError: (error, stack) => errors.add('duration'),
        ),
        progress: ReaderHistoryWriter(
          write: () async => throw StateError('progress'),
          onError: (error, stack) => errors.add('progress'),
        ),
        pauseAutoReading: (_) {},
        onClosed: () => closed++,
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 1);
      session.scheduleProgress();
      await expectLater(
        session.dispose(),
        throwsA(
          isA<ReaderSessionFailure>().having(
            (failure) => failure.failures.map((entry) => entry.operation),
            'both save failures',
            unorderedEquals(['progress', 'duration']),
          ),
        ),
      );
      expect(errors, ['progress', 'duration']);
      expect(closed, 1);
    },
  );

  test(
    'close notification failure is observable and is never retried implicitly',
    () async {
      var calls = 0;
      final session = ReaderSession(
        durations: ReadingSessionTracker(onDuration: (_) async {}),
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (_) {},
        onClosed: () {
          calls++;
          throw StateError('sync scheduling');
        },
        foreground: true,
      );
      final matchesNotification = isA<ReaderSessionFailure>().having(
        (failure) => failure.failures.single.operation,
        'notification error',
        'notification',
      );
      await expectLater(session.dispose(), throwsA(matchesNotification));
      await expectLater(session.dispose(), throwsA(matchesNotification));
      expect(calls, 1);
    },
  );

  testWidgets('sync waits for progress even when duration finishes first', (
    tester,
  ) async {
    final progress = Completer<void>();
    var elapsed = Duration.zero;
    final durations = <Duration>[];
    var closed = false;
    final session = ReaderSession(
      durations: ReadingSessionTracker(
        elapsedNow: () => elapsed,
        onDuration: (duration) async => durations.add(duration),
      ),
      progress: ReaderHistoryWriter(
        write: () => progress.future,
        onError: (_, _) {},
      ),
      pauseAutoReading: (_) {},
      onClosed: () => closed = true,
      foreground: true,
    );
    session.setContentReady(true);
    elapsed = const Duration(seconds: 3);
    session.scheduleProgress();
    await tester.pump(const Duration(seconds: 1));
    final closing = session.dispose();
    final observed = expectLater(
      closing,
      throwsA(
        isA<ReaderSessionFailure>().having(
          (failure) => failure.failures.single.operation,
          'progress error',
          'progress',
        ),
      ),
    );
    elapsed = const Duration(seconds: 100);
    await tester.pump();
    expect(durations, [const Duration(seconds: 3)]);
    expect(closed, isFalse);
    progress.completeError(
      StateError('failed progress is reported and drained'),
    );
    await tester.pump();
    await observed;
    expect(closed, isTrue);
  });

  test(
    'failed preparation resumes reading without counting the save wait',
    () async {
      var elapsed = Duration.zero;
      final progressStarted = Completer<void>();
      final pendingProgress = Completer<void>();
      var progressWrites = 0;
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async => recorded.add(duration),
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(
          write: () async {
            progressWrites++;
            if (progressWrites == 1) {
              progressStarted.complete();
              await pendingProgress.future;
            }
          },
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      session.scheduleProgress();
      elapsed = const Duration(seconds: 10);
      final preparing = session.prepareForExit();
      expect(session.prepareForExit(), same(preparing));
      final observed = expectLater(
        preparing,
        throwsA(isA<ReaderSessionFailure>()),
      );
      expect(tracker.isRunning, isFalse);
      await progressStarted.future;
      elapsed = const Duration(seconds: 100);
      pendingProgress.completeError(StateError('progress cannot be saved'));
      await observed;
      expect(tracker.isRunning, isTrue);

      elapsed = const Duration(seconds: 120);
      final release = await session.prepareForExit();
      expect(tracker.isRunning, isFalse);
      release();
      expect(tracker.isRunning, isTrue);
      await session.dispose();
      expect(recorded, const [Duration(seconds: 10), Duration(seconds: 20)]);
      expect(progressWrites, 2);
    },
  );

  test('a hold restores the latest foreground and readiness state', () async {
    var elapsed = Duration.zero;
    final recorded = <Duration>[];
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (duration) async => recorded.add(duration),
    );
    final session = ReaderSession(
      durations: tracker,
      progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
      pauseAutoReading: (_) {},
      onClosed: () {},
      foreground: true,
    );
    session.setContentReady(true);
    elapsed = const Duration(seconds: 10);
    final release = session.holdForExit();
    expect(tracker.isRunning, isFalse);
    session.setForeground(false);
    session.setContentReady(false);
    session.setForeground(true);
    elapsed = const Duration(seconds: 100);
    release();
    expect(tracker.isRunning, isFalse);
    session.setContentReady(true);
    expect(tracker.isRunning, isTrue);
    elapsed = const Duration(seconds: 105);
    session.setForeground(false);
    final releaseInBackground = session.holdForExit();
    session.setContentReady(false);
    session.setContentReady(true);
    elapsed = const Duration(seconds: 200);
    releaseInBackground();
    expect(tracker.isRunning, isFalse);
    await session.dispose();
    expect(recorded, const [Duration(seconds: 10), Duration(seconds: 5)]);
  });

  test(
    'independent holds compose and old releases cannot release a new hold',
    () async {
      var elapsed = Duration.zero;
      final recorded = <Duration>[];
      final paused = <bool>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async => recorded.add(duration),
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: paused.add,
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      final first = session.holdForExit();
      final second = session.holdForExit();
      first();
      first();
      expect(tracker.isRunning, isFalse);
      expect(paused.last, isTrue);
      elapsed = const Duration(seconds: 100);
      second();
      expect(tracker.isRunning, isTrue);
      elapsed = const Duration(seconds: 110);
      final third = session.holdForExit();
      first();
      second();
      expect(tracker.isRunning, isFalse);
      expect(paused.last, isTrue);
      elapsed = const Duration(seconds: 200);
      third();
      elapsed = const Duration(seconds: 205);
      await session.dispose();
      third();
      expect(tracker.isRunning, isFalse);
      expect(recorded, const [
        Duration(seconds: 10),
        Duration(seconds: 10),
        Duration(seconds: 5),
      ]);
    },
  );

  test(
    'preparation drains late progress arriving while duration is pending',
    () async {
      var elapsed = Duration.zero;
      final durationStarted = Completer<void>();
      final releaseDuration = Completer<void>();
      final progressStarted = Completer<void>();
      final releaseProgress = Completer<void>();
      final events = <String>[];
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          checkpointInterval: const Duration(days: 1),
          onDuration: (_) async {
            events.add('duration');
            durationStarted.complete();
            await releaseDuration.future;
          },
        ),
        progress: ReaderHistoryWriter(
          delay: const Duration(days: 1),
          write: () async {
            events.add('progress');
            progressStarted.complete();
            await releaseProgress.future;
          },
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () => events.add('notification'),
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      final preparing = session.prepareForExit();
      await durationStarted.future;
      session.scheduleProgress();
      releaseDuration.complete();
      await progressStarted.future;
      expect(events, ['duration', 'progress']);
      releaseProgress.complete();
      final release = await preparing;
      expect(events, ['duration', 'progress', 'notification']);
      release();
      await session.dispose();
    },
  );

  test(
    'dispose joins preparation without restarting or repeating its writes',
    () async {
      var elapsed = Duration.zero;
      final durationStarted = Completer<void>();
      final releaseDuration = Completer<void>();
      final recorded = <Duration>[];
      var progressWrites = 0;
      var notifications = 0;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          recorded.add(duration);
          durationStarted.complete();
          await releaseDuration.future;
        },
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(
          write: () async => progressWrites++,
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () => notifications++,
        foreground: true,
      );
      session.setContentReady(true);
      session.scheduleProgress();
      elapsed = const Duration(seconds: 10);
      final preparing = session.prepareForExit();
      await durationStarted.future;
      final closing = session.dispose();
      expect(session.dispose(), same(closing));
      elapsed = const Duration(seconds: 100);
      session.setForeground(true);
      session.setContentReady(true);
      session.scheduleProgress();
      expect(tracker.isRunning, isFalse);
      releaseDuration.complete();
      final release = await preparing;
      release();
      await closing;
      release();
      expect(tracker.isRunning, isFalse);
      expect(recorded, const [Duration(seconds: 10)]);
      expect(progressWrites, 1);
      expect(notifications, 1);
      await expectLater(session.prepareForExit(), throwsStateError);
    },
  );

  test(
    'both saves and notification failures preserve their original diagnostics',
    () async {
      var elapsed = Duration.zero;
      final durationError = StateError('duration');
      final progressError = StateError('progress');
      final notificationError = StateError('notification');
      final durationStack = StackTrace.current;
      final progressStack = StackTrace.current;
      final notificationStack = StackTrace.current;
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          checkpointInterval: const Duration(days: 1),
          onDuration: (_) => Future.error(durationError, durationStack),
        ),
        progress: ReaderHistoryWriter(
          write: () => Future.error(progressError, progressStack),
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () =>
            Future<void>.error(notificationError, notificationStack),
        foreground: true,
      );
      session.setContentReady(true);
      session.scheduleProgress();
      elapsed = const Duration(seconds: 10);
      await expectLater(
        session.dispose(),
        throwsA(
          isA<ReaderSessionFailure>()
              .having(
                (failure) => failure.failures.map((entry) => entry.operation),
                'all operations',
                unorderedEquals(['duration', 'progress', 'notification']),
              )
              .having(
                (failure) => failure.failures
                    .singleWhere((entry) => entry.operation == 'duration')
                    .error,
                'duration diagnostics',
                isA<ReadingDurationFailure>()
                    .having(
                      (failure) => failure.cause,
                      'cause',
                      same(durationError),
                    )
                    .having(
                      (failure) => failure.stackTrace,
                      'stack',
                      same(durationStack),
                    ),
              )
              .having(
                (failure) => failure.failures
                    .singleWhere((entry) => entry.operation == 'progress')
                    .error,
                'progress diagnostics',
                isA<ReaderProgressFailure>()
                    .having(
                      (failure) => failure.cause,
                      'cause',
                      same(progressError),
                    )
                    .having(
                      (failure) => failure.stackTrace,
                      'stack',
                      same(progressStack),
                    ),
              )
              .having(
                (failure) => failure.failures
                    .singleWhere((entry) => entry.operation == 'notification')
                    .error,
                'notification cause',
                same(notificationError),
              )
              .having(
                (failure) => failure.failures
                    .singleWhere((entry) => entry.operation == 'notification')
                    .stackTrace,
                'notification stack',
                same(notificationStack),
              ),
        ),
      );
    },
  );

  test(
    'reading resumed after a later shutdown failure marks new duration for sync',
    () async {
      var elapsed = Duration.zero;
      final recorded = <Duration>[];
      var notifications = 0;
      final session = ReaderSession(
        durations: ReadingSessionTracker(
          elapsedNow: () => elapsed,
          checkpointInterval: const Duration(days: 1),
          onDuration: (duration) async => recorded.add(duration),
        ),
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (_) {},
        onClosed: () => notifications++,
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      final firstPreparation = session.prepareForExit();
      final releaseFirst = await firstPreparation;
      expect(session.prepareForExit(), same(firstPreparation));
      expect(notifications, 1);
      elapsed = const Duration(seconds: 100);
      releaseFirst();
      elapsed = const Duration(seconds: 120);
      final secondPreparation = session.prepareForExit();
      final releaseSecond = await secondPreparation;
      expect(notifications, 2);
      releaseFirst();
      expect(session.prepareForExit(), same(secondPreparation));
      expect(recorded, const [Duration(seconds: 10), Duration(seconds: 20)]);
      await session.dispose();
      releaseSecond();
      expect(notifications, 2);
    },
  );

  test('failed preparation releases only its own hold', () async {
    var elapsed = Duration.zero;
    var notifications = 0;
    final recorded = <Duration>[];
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (duration) async => recorded.add(duration),
    );
    final session = ReaderSession(
      durations: tracker,
      progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
      pauseAutoReading: (_) {},
      onClosed: () {
        if (++notifications == 1) throw StateError('cannot schedule sync');
      },
      foreground: true,
    );
    session.setContentReady(true);
    elapsed = const Duration(seconds: 10);
    final hostRelease = session.holdForExit();
    await expectLater(
      session.prepareForExit(),
      throwsA(isA<ReaderSessionFailure>()),
    );
    expect(tracker.isRunning, isFalse);
    elapsed = const Duration(seconds: 100);
    hostRelease();
    expect(tracker.isRunning, isTrue);
    elapsed = const Duration(seconds: 105);
    await session.dispose();
    expect(recorded, const [Duration(seconds: 10), Duration(seconds: 5)]);
    expect(notifications, 2);
  });

  test(
    'progress arriving during notification is saved and notified before prepare completes',
    () async {
      final notificationStarted = Completer<void>();
      final releaseNotification = Completer<void>();
      final events = <String>[];
      var notifications = 0;
      final session = ReaderSession(
        durations: ReadingSessionTracker(onDuration: (_) async {}),
        progress: ReaderHistoryWriter(
          delay: const Duration(days: 1),
          write: () async => events.add('progress'),
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () async {
          events.add('notification');
          if (++notifications == 1) {
            notificationStarted.complete();
            await releaseNotification.future;
          }
        },
        foreground: true,
      );
      final preparing = session.prepareForExit();
      await notificationStarted.future;
      session.scheduleProgress();
      releaseNotification.complete();
      await preparing;
      expect(events, ['notification', 'progress', 'notification']);
      await session.dispose();
      expect(notifications, 2);
    },
  );

  test('failed resume reports both errors and settles preparation', () async {
    var elapsed = Duration.zero;
    final notificationError = StateError('cannot notify sync');
    final notificationStack = StackTrace.current;
    final resumeError = StateError('cannot resume auto reading');
    final resumeStack = StackTrace.current;
    final recorded = <Duration>[];
    var failNotification = true;
    var failResume = true;
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (duration) async => recorded.add(duration),
    );
    final session = ReaderSession(
      durations: tracker,
      progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
      pauseAutoReading: (paused) {
        if (!paused && failResume) {
          Error.throwWithStackTrace(resumeError, resumeStack);
        }
      },
      onClosed: () {
        if (failNotification) {
          Error.throwWithStackTrace(notificationError, notificationStack);
        }
      },
      foreground: true,
    );
    session.setContentReady(true);
    elapsed = const Duration(seconds: 10);
    await expectLater(
      session.prepareForExit().timeout(const Duration(seconds: 5)),
      throwsA(
        isA<ReaderSessionFailure>()
            .having(
              (failure) => failure.failures.map((entry) => entry.operation),
              'original failure and failed recovery',
              ['notification', 'resume'],
            )
            .having(
              (failure) => failure.failures.map((entry) => entry.error),
              'original errors',
              [same(notificationError), same(resumeError)],
            )
            .having(
              (failure) => failure.failures.map((entry) => entry.stackTrace),
              'original stacks',
              [same(notificationStack), same(resumeStack)],
            ),
      ),
    );
    expect(tracker.isRunning, isTrue);
    failNotification = false;
    failResume = false;
    elapsed = const Duration(seconds: 15);
    final release = await session.prepareForExit();
    expect(tracker.isRunning, isFalse);
    release();
    expect(tracker.isRunning, isTrue);
    await session.dispose();
    expect(recorded, const [Duration(seconds: 10), Duration(seconds: 5)]);
  });

  test(
    'a synchronously failed hold restores the clock and preserves other holds',
    () async {
      var elapsed = Duration.zero;
      final pauseError = StateError('auto reading pause failed');
      var failPause = true;
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async => recorded.add(duration),
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (paused) {
          if (paused && failPause) throw pauseError;
        },
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      expect(session.holdForExit, throwsA(same(pauseError)));
      expect(tracker.isRunning, isTrue);
      failPause = false;
      elapsed = const Duration(seconds: 15);
      final release = session.holdForExit();
      expect(tracker.isRunning, isFalse);
      failPause = true;
      expect(session.holdForExit, throwsA(same(pauseError)));
      expect(tracker.isRunning, isFalse);
      failPause = false;
      elapsed = const Duration(seconds: 100);
      release();
      expect(tracker.isRunning, isTrue);
      elapsed = const Duration(seconds: 105);
      await session.dispose();
      expect(recorded, const [
        Duration(seconds: 10),
        Duration(seconds: 5),
        Duration(seconds: 5),
      ]);
    },
  );

  test(
    'progress repaired without a new reading revision is notified again',
    () async {
      var writes = 0;
      final notifications = <int>[];
      final session = ReaderSession(
        durations: ReadingSessionTracker(onDuration: (_) async {}),
        progress: ReaderHistoryWriter(
          write: () async {
            if (++writes == 1) throw StateError('progress failed');
          },
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () => notifications.add(writes),
        foreground: false,
      );
      session.scheduleProgress();
      await expectLater(
        session.prepareForExit(),
        throwsA(isA<ReaderSessionFailure>()),
      );
      expect(notifications, [1]);
      final release = await session.prepareForExit();
      expect(writes, 2);
      expect(notifications, [1, 2]);
      await session.dispose();
      release();
      expect(notifications, [1, 2]);
    },
  );

  test(
    'duration repaired while backgrounded is notified after its commit',
    () async {
      var elapsed = Duration.zero;
      var writes = 0;
      var persisted = Duration.zero;
      final notifications = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          if (++writes <= 2) {
            throw PersistenceFailure(
              commitState: PersistenceCommitState.notCommitted,
              cause: StateError('duration failed'),
              stackTrace: StackTrace.current,
            );
          }
          persisted += duration;
        },
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(write: () async {}, onError: (_, _) {}),
        pauseAutoReading: (_) {},
        onClosed: () => notifications.add(persisted),
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 10);
      session.setForeground(false);
      await expectLater(
        session.prepareForExit(),
        throwsA(isA<ReaderSessionFailure>()),
      );
      expect(tracker.isRunning, isFalse);
      expect(notifications, [Duration.zero]);
      final release = await session.prepareForExit();
      expect(writes, 3);
      expect(persisted, const Duration(seconds: 10));
      expect(notifications, const [Duration.zero, Duration(seconds: 10)]);
      await session.dispose();
      release();
      expect(notifications, const [Duration.zero, Duration(seconds: 10)]);
    },
  );

  for (final releaseOldFirst in [true, false]) {
    test(
      'new progress invalidates completed preparation and keeps independent holds '
      '(release old first: $releaseOldFirst)',
      () async {
        final secondWriteStarted = Completer<void>();
        final releaseSecondWrite = Completer<void>();
        final images = ImageWork();
        var writes = 0;
        var notifications = 0;
        final tracker = ReadingSessionTracker(
          elapsedNow: () => Duration.zero,
          checkpointInterval: const Duration(days: 1),
          onDuration: (_) async {},
        );
        final session = ReaderSession(
          imageWork: images,
          durations: tracker,
          progress: ReaderHistoryWriter(
            delay: const Duration(days: 1),
            write: () async {
              if (++writes == 2) {
                secondWriteStarted.complete();
                await releaseSecondWrite.future;
              }
            },
            onError: (_, _) {},
          ),
          pauseAutoReading: (_) {},
          onClosed: () => notifications++,
          foreground: true,
        );
        session.setContentReady(true);
        session.scheduleProgress();
        final firstPreparation = session.prepareForExit();
        final releaseFirst = await firstPreparation;
        expect(session.prepareForExit(), same(firstPreparation));
        expect(images.start(), isNull);
        expect(writes, 1);
        session.scheduleProgress();
        final secondPreparation = session.prepareForExit();
        expect(secondPreparation, isNot(same(firstPreparation)));
        expect(session.prepareForExit(), same(secondPreparation));
        var secondCompleted = false;
        unawaited(secondPreparation.then((_) => secondCompleted = true));
        await secondWriteStarted.future;
        expect(secondCompleted, isFalse);
        expect(notifications, 1);
        if (releaseOldFirst) {
          releaseFirst();
          expect(tracker.isRunning, isFalse);
          expect(session.isHeld, isTrue);
          expect(session.prepareForExit(), same(secondPreparation));
          expect(images.start(), isNull);
        }
        releaseSecondWrite.complete();
        final releaseSecond = await secondPreparation;
        expect(writes, 2);
        expect(notifications, 2);
        expect(session.prepareForExit(), same(secondPreparation));
        releaseSecond();
        expect(tracker.isRunning, releaseOldFirst);
        if (!releaseOldFirst) {
          expect(session.isHeld, isTrue);
          expect(images.start(), isNull);
          releaseFirst();
        }
        expect(tracker.isRunning, isTrue);
        expect(session.isHeld, isFalse);
        final resumedImage = images.start();
        expect(resumedImage, isNotNull);
        resumedImage!.finish();
        releaseFirst();
        releaseSecond();
        await session.dispose();
      },
    );
  }

  test(
    'failed fresh preparation cannot release an earlier successful hold',
    () async {
      var writes = 0;
      final tracker = ReadingSessionTracker(
        elapsedNow: () => Duration.zero,
        checkpointInterval: const Duration(days: 1),
        onDuration: (_) async {},
      );
      final session = ReaderSession(
        durations: tracker,
        progress: ReaderHistoryWriter(
          write: () async {
            if (++writes == 2) throw StateError('late progress failed');
          },
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () {},
        foreground: true,
      );
      session.setContentReady(true);
      session.scheduleProgress();
      final firstPreparation = session.prepareForExit();
      final releaseFirst = await firstPreparation;
      session.scheduleProgress();
      final secondPreparation = session.prepareForExit();
      expect(secondPreparation, isNot(same(firstPreparation)));
      await expectLater(
        secondPreparation,
        throwsA(isA<ReaderSessionFailure>()),
      );
      expect(tracker.isRunning, isFalse);
      expect(session.isHeld, isTrue);
      final thirdPreparation = session.prepareForExit();
      final releaseThird = await thirdPreparation;
      expect(writes, 3);
      releaseFirst();
      expect(tracker.isRunning, isFalse);
      expect(session.isHeld, isTrue);
      expect(session.prepareForExit(), same(thirdPreparation));
      releaseThird();
      expect(tracker.isRunning, isTrue);
      await session.dispose();
    },
  );
}

Future<ReaderSessionFailure> _sessionFailure(Future<dynamic> operation) async {
  try {
    await operation;
  } catch (error) {
    expect(error, isA<ReaderSessionFailure>());
    return error as ReaderSessionFailure;
  }
  throw TestFailure('Expected a reader session failure');
}

Iterable<Object> _sessionCauses(Object error) sync* {
  if (error is ReaderSessionFailure) {
    for (final failure in error.failures) {
      yield* _sessionCauses(failure.error);
    }
  } else if (error is ImageWorkFailure) {
    for (final failure in error.failures) {
      yield* _sessionCauses(failure.error);
    }
  } else {
    yield error;
  }
}
