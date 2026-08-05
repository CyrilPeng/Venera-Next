import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';

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
}
