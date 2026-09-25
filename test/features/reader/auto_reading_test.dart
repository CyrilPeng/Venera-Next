import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/auto_reading.dart';

void main() {
  Future<void> frames(
    WidgetTester tester,
    int count, [
    int milliseconds = 20,
  ]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(Duration(milliseconds: milliseconds));
    }
  }

  testWidgets('smooth speed is frame independent and changes immediately', (
    tester,
  ) async {
    var speed = 100.0;
    var distance = 0.0;
    final reader = AutoReadingController(
      settings: () => AutoReadingSettings(pixelsPerSecond: speed),
      canAdvance: () => true,
      advance: (delta) {
        distance += delta;
        return AutoReadingStep.advanced;
      },
    );
    addTearDown(reader.dispose);
    reader.start();
    await tester.pump();
    await frames(tester, 50);
    expect(distance, closeTo(100, 0.01));
    speed = 200;
    await frames(tester, 100, 10);
    expect(distance, closeTo(300, 0.01));
    reader.stop();
    await frames(tester, 10);
    expect(distance, closeTo(300, 0.01));
  });

  testWidgets('step frequency and distance are independent settings', (
    tester,
  ) async {
    final steps = <double>[];
    final reader = AutoReadingController(
      settings: () => const AutoReadingSettings(
        stepped: true,
        stepsPerSecond: 2,
        pixelsPerStep: 30,
      ),
      canAdvance: () => true,
      advance: (delta) {
        steps.add(delta);
        return AutoReadingStep.advanced;
      },
    );
    addTearDown(reader.dispose);
    reader.start();
    await tester.pump();
    await frames(tester, 50);
    expect(steps, [30, 30]);
    reader.stop();
  });

  testWidgets('waiting and nested pauses do not accumulate a catch-up jump', (
    tester,
  ) async {
    var ready = false;
    var distance = 0.0;
    final reader = AutoReadingController(
      settings: () => const AutoReadingSettings(pixelsPerSecond: 100),
      canAdvance: () => ready,
      advance: (delta) {
        distance += delta;
        return AutoReadingStep.advanced;
      },
    );
    addTearDown(reader.dispose);
    reader.start();
    await tester.pump();
    await frames(tester, 100);
    expect(reader.status, AutoReadingStatus.waiting);
    expect(distance, 0);
    ready = true;
    await frames(tester, 5);
    expect(distance, closeTo(10, 0.01));
    reader.pause('touch', true);
    reader.pause('background', true);
    await frames(tester, 50);
    reader.pause('touch', false);
    await frames(tester, 50);
    expect(distance, closeTo(10, 0.01));
    reader.pause('background', false);
    await tester.pump();
    await frames(tester, 5);
    expect(distance, closeTo(20, 0.01));
    reader.stop();
  });

  testWidgets('chapter end stops cleanly and one toggle restarts', (
    tester,
  ) async {
    var calls = 0;
    final reader = AutoReadingController(
      settings: () => const AutoReadingSettings(gallery: true, pageInterval: 1),
      canAdvance: () => true,
      advance: (_) {
        calls++;
        return AutoReadingStep.finished;
      },
    );
    addTearDown(reader.dispose);
    reader.toggle();
    await tester.pump();
    await frames(tester, 51);
    expect(calls, 1);
    expect(reader.isActive, isFalse);
    reader.toggle();
    await tester.pump();
    await frames(tester, 51);
    expect(calls, 2);
    expect(reader.isActive, isFalse);
  });

  testWidgets(
    'gallery interval changes while active and stalled frames are bounded',
    (tester) async {
      var interval = 5.0;
      var turns = 0;
      final reader = AutoReadingController(
        settings: () =>
            AutoReadingSettings(gallery: true, pageInterval: interval),
        canAdvance: () => true,
        advance: (_) {
          turns++;
          return AutoReadingStep.advanced;
        },
      );
      addTearDown(reader.dispose);
      reader.start();
      await tester.pump();
      await frames(tester, 50);
      expect(turns, 0);
      interval = 1;
      await frames(tester, 1);
      expect(turns, 1);
      await tester.pump(const Duration(minutes: 1));
      expect(turns, 1);
      reader.stop();
    },
  );
}
