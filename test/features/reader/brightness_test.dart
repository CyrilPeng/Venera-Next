import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/brightness.dart';

void main() {
  group('reader brightness', () {
    test('normalizes missing and out-of-range values', () {
      expect(normalizeReaderBrightness(null), defaultReaderBrightness);
      expect(normalizeReaderBrightness(5), readerBrightnessMin);
      expect(normalizeReaderBrightness(120), readerBrightnessMax);
      expect(normalizeReaderBrightness(42.6), 43);
    });

    test('maps brightness to a black overlay opacity', () {
      expect(readerBrightnessOverlayOpacity(enabled: false, brightness: 20), 0);
      expect(readerBrightnessOverlayOpacity(enabled: true, brightness: 100), 0);
      expect(
        readerBrightnessOverlayOpacity(enabled: true, brightness: 50),
        0.5,
      );
      expect(
        readerBrightnessOverlayOpacity(enabled: true, brightness: 20),
        0.8,
      );
    });
  });

  testWidgets('brightness overlay does not intercept reader gestures', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 200,
          height: 200,
          child: ReaderBrightnessOverlay(enabled: true, brightness: 50),
        ),
      ),
    );

    expect(find.byType(IgnorePointer), findsOneWidget);
    expect(
      tester.widget<IgnorePointer>(find.byType(IgnorePointer)).ignoring,
      isTrue,
    );
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      Colors.black.withValues(alpha: 0.5),
    );
  });

  testWidgets('brightness control exposes the configured range', (
    tester,
  ) async {
    bool? enabledValue;
    int? brightnessValue;
    int? brightnessEndValue;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: ReaderBrightnessControl(
              enabled: true,
              brightness: 50,
              onEnabledChanged: (value) => enabledValue = value,
              onBrightnessChanged: (value) => brightnessValue = value,
              onBrightnessChangeEnd: (value) => brightnessEndValue = value,
              compact: true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    expect(enabledValue, isFalse);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, readerBrightnessMin);
    expect(slider.max, readerBrightnessMax);
    expect(slider.value, 50);
    slider.onChanged!(75);
    slider.onChangeEnd!(70);
    expect(brightnessValue, 75);
    expect(brightnessEndValue, 70);
    expect(tester.takeException(), isNull);
  });
}
