import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_swipe_indicator.dart';
import 'package:venera_next/foundation/appdata.dart';

// Keep real ScrollPositions at a chosen overscroll until the next input.
class _HeldPhysics extends ScrollPhysics {
  const _HeldPhysics();
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => null;
}

class _Controller extends ScrollController {
  bool disposed = false;
  void signal() => notifyListeners();
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _Fixture {
  _Fixture(this.tester);
  final WidgetTester tester;
  final first = _Controller(), second = _Controller();
  ScrollController? selected;
  bool previous = true, show = true;
  int clients = 1;

  Future<void> mount({
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness).copyWith(
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: brightness,
            ).copyWith(
              surfaceContainerLow: Colors.black,
              surfaceContainerHighest: Colors.white,
            ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Column(
          children: [
            if (show)
              ChapterSwipeIndicator(
                key: const ValueKey('indicator'),
                controller: selected,
                isPrev: previous,
              ),
            for (var i = 0; i < clients; i++)
              SizedBox(
                height: 80,
                child: SingleChildScrollView(
                  key: ValueKey(('first', i)),
                  controller: first,
                  physics: const _HeldPhysics(),
                  child: const SizedBox(height: 400),
                ),
              ),
            SizedBox(
              height: 80,
              child: SingleChildScrollView(
                key: const ValueKey('second'),
                controller: second,
                physics: const _HeldPhysics(),
                child: const SizedBox(height: 400),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  }
}

// Observe the rendered fill, without accessing the State or private painter data.
Future<int> _filledPixels(WidgetTester tester) async {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(ChapterSwipeIndicator),
      matching: find.byType(CustomPaint),
    ),
  );
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    paint.painter!.paint(Canvas(recorder), const Size(200, 32));
    final picture = recorder.endRecording();
    final image = await picture.toImage(200, 32);
    final data = (await image.toByteData())!;
    var filled = 0;
    for (var x = 0; x < 200; x++) {
      if (data.getUint8((16 * 200 + x) * 4) > 127) filled++;
    }
    image.dispose();
    picture.dispose();
    return filled;
  }))!;
}

void main() {
  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });

  testWidgets(
    'overscroll fills the matching edge and clamps at the threshold',
    (tester) async {
      final f = _Fixture(tester);
      f.selected = f.first;
      await f.mount();
      for (final pair in [(-80.0, 100), (-200.0, 200), (40.0, 0)]) {
        f.first.jumpTo(pair.$1);
        await tester.pump();
        expect(await _filledPixels(tester), pair.$2);
      }
      await f.dispose();
    },
  );

  testWidgets('same element follows direction changes without another scroll', (
    tester,
  ) async {
    final f = _Fixture(tester);
    f.selected = f.first;
    await f.mount();
    f.first.jumpTo(-80);
    await tester.pump();
    expect(await _filledPixels(tester), 100);
    final element = tester.element(find.byType(ChapterSwipeIndicator));
    f.previous = false;
    await f.mount();
    expect(tester.element(find.byType(ChapterSwipeIndicator)), same(element));
    expect(find.text('Swipe up for next chapter'), findsOneWidget);
    expect(await _filledPixels(tester), 0);
    f.first.jumpTo(f.first.position.maxScrollExtent + 120);
    await tester.pump();
    expect(await _filledPixels(tester), 150);
    await f.dispose();
  });

  testWidgets('mount and controller replacement sample existing overscroll', (
    tester,
  ) async {
    final f = _Fixture(tester)..show = false;
    await f.mount();
    f.first.jumpTo(-40);
    f.second.jumpTo(-120);
    f.show = true;
    f.selected = f.first;
    await f.mount();
    await tester.pump();
    expect(await _filledPixels(tester), 50);
    f.selected = f.second;
    await f.mount();
    expect(await _filledPixels(tester), 150);
    f.first.jumpTo(-160);
    await tester.pump();
    expect(await _filledPixels(tester), 150);
    expect(f.first.disposed, isFalse);
    f.show = false;
    await f.mount();
    f.second.jumpTo(-80);
    await tester.pump();
    expect(f.second.disposed, isFalse);
    expect(tester.takeException(), isNull);
    await f.dispose();
  });

  testWidgets(
    'detached and ambiguous controllers clear fill without throwing',
    (tester) async {
      final f = _Fixture(tester);
      f.selected = f.first;
      await f.mount();
      f.first.jumpTo(-80);
      await tester.pump();
      f.clients = 0;
      await f.mount();
      f.first.signal();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await _filledPixels(tester), 0);
      f.clients = 2;
      await f.mount();
      f.first.signal();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await _filledPixels(tester), 0);
      f.selected = null;
      await f.mount();
      f.first.signal();
      await tester.pump();
      expect(await _filledPixels(tester), 0);
      await f.dispose();
    },
  );

  for (final scenario in [
    (const Size(375, 740), Brightness.dark, 2.0),
    (const Size(812, 375), Brightness.light, 3.0),
  ]) {
    testWidgets(
      'chapter hint stays visible with large text at ${scenario.$1}',
      (tester) async {
        tester.view.physicalSize = scenario.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = _Fixture(tester);
        f.selected = f.first;
        await f.mount(textScale: scenario.$3, brightness: scenario.$2);
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(
          find.text('Swipe down for previous chapter'),
        );
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(scenario.$1.width));
        await f.dispose();
      },
    );
  }
}
