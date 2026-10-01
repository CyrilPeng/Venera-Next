import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/history_writer.dart';
import 'package:venera_next/features/reader/reader_session.dart';
import 'package:venera_next/features/reader/reading_session.dart';

void main() {
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
          write: () async => fail('pending progress must flush on exit'),
          flush: () => flushes++,
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
          write: () async => events.add('write'),
          flush: () => events.add('flush'),
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
    'failed duration and progress writes still close with reported errors',
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
          write: () async {},
          flush: () => throw StateError('progress'),
          onError: (error, stack) => errors.add('progress'),
        ),
        pauseAutoReading: (_) {},
        onClosed: () => closed++,
        foreground: true,
      );
      session.setContentReady(true);
      elapsed = const Duration(seconds: 1);
      session.scheduleProgress();
      await session.dispose();
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
        progress: ReaderHistoryWriter(
          write: () async {},
          flush: () {},
          onError: (_, _) {},
        ),
        pauseAutoReading: (_) {},
        onClosed: () {
          calls++;
          throw StateError('sync scheduling');
        },
        foreground: true,
      );
      await expectLater(session.dispose(), throwsStateError);
      await expectLater(session.dispose(), throwsStateError);
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
        flush: () => fail('already submitted progress must not flush again'),
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
    elapsed = const Duration(seconds: 100);
    await tester.pump();
    expect(durations, [const Duration(seconds: 3)]);
    expect(closed, isFalse);
    progress.completeError(
      StateError('failed progress is reported and drained'),
    );
    await tester.pump();
    await closing;
    expect(closed, isTrue);
  });
}
