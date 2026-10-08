import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/eink_refresh.dart';
import 'package:venera_next/features/reader/eink_refresh_controller.dart';

void main() {
  group('EInkRefreshController', () {
    test(
      'refreshes on the first change and then at the configured interval',
      () {
        final controller = EInkRefreshController();
        addTearDown(controller.dispose);

        expect(
          controller.onPageChanged(
            interval: 3,
            durationMilliseconds: 100,
            style: EInkRefreshStyle.black,
          ),
          isTrue,
        );
        expect(
          controller.onPageChanged(
            interval: 3,
            durationMilliseconds: 100,
            style: EInkRefreshStyle.black,
          ),
          isFalse,
        );
        expect(
          controller.onPageChanged(
            interval: 3,
            durationMilliseconds: 100,
            style: EInkRefreshStyle.black,
          ),
          isFalse,
        );
        expect(
          controller.onPageChanged(
            interval: 3,
            durationMilliseconds: 100,
            style: EInkRefreshStyle.black,
          ),
          isTrue,
        );
      },
    );

    test('resets the counter when the interval changes', () {
      final controller = EInkRefreshController();
      addTearDown(controller.dispose);

      controller.onPageChanged(
        interval: 4,
        durationMilliseconds: 100,
        style: EInkRefreshStyle.black,
      );

      expect(
        controller.onPageChanged(
          interval: 2,
          durationMilliseconds: 100,
          style: EInkRefreshStyle.white,
        ),
        isTrue,
      );
      expect(controller.request!.style, EInkRefreshStyle.white);
    });
  });

  testWidgets('white then black refresh uses two phases', (tester) async {
    final controller = EInkRefreshController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(child: EInkRefreshOverlay(controller: controller)),
          ],
        ),
      ),
    );

    controller.onPageChanged(
      interval: 1,
      durationMilliseconds: 100,
      style: EInkRefreshStyle.whiteThenBlack,
    );
    await tester.pump();
    final refreshColor = find.descendant(
      of: find.byType(EInkRefreshOverlay),
      matching: find.byType(ColoredBox),
    );
    expect(refreshColor, findsOneWidget);
    expect(tester.widget<ColoredBox>(refreshColor).color, Colors.white);

    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<ColoredBox>(refreshColor).color, Colors.black);

    await tester.pump(const Duration(milliseconds: 50));
    expect(refreshColor, findsNothing);
  });
}
