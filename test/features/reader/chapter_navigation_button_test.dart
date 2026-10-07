import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/chapter_navigation.dart';
import 'package:venera_next/features/reader/chapter_navigation_button.dart';

void main() {
  testWidgets(
    'hiding removes interaction immediately while the visual exit animates',
    (tester) async {
      final changes = ValueNotifier<int>(0);
      final controller = ReaderChapterNavigationController(
        onChanged: () => changes.value++,
      );
      final selected = <int>[];
      final request = ReaderChapterNavigationRequest(
        identity: Object(),
        isCurrent: () => true,
        canPrevious: true,
        canNext: true,
        reversed: false,
        select: selected.add,
      );
      controller.report(request, 1);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: changes,
                builder: (_, _, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ReaderChapterNavigationButton(action: controller.action),
                  ],
                ),
              ),
            ),
          ),
        );
        final captured = tester
            .widget<IconButton>(find.byType(IconButton))
            .onPressed!;
        controller.report(request, 0);
        await tester.pump();
        expect(tester.getRect(find.byType(IconButton)).bottom, lessThan(600));
        expect(
          tester
              .widget<AnimatedPositioned>(find.byType(AnimatedPositioned))
              .duration,
          const Duration(milliseconds: 180),
        );
        expect(
          tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNull,
        );
        expect(
          tester.widget<ExcludeFocus>(find.byType(ExcludeFocus).last).excluding,
          true,
        );
        expect(
          tester
              .widget<ExcludeSemantics>(find.byType(ExcludeSemantics).last)
              .excluding,
          true,
        );
        expect(find.byType(IconButton).hitTestable(), findsNothing);
        captured();
        expect(selected, isEmpty);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        changes.dispose();
      }
    },
  );

  setUpAll(() async {
    final font = Platform.environment['FLOATING_NAV_QA_FONT'];
    if (font == null) return;
    await (FontLoader(
      'FloatingNavigationQA',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('MaterialIcons')..addFont(
          File(
            'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  for (final scenario in [
    (size: Size(375, 667), dark: false, scale: 1.0),
    (size: Size(667, 375), dark: true, scale: 3.2),
    (size: Size(1024, 768), dark: false, scale: 2.0),
  ]) {
    for (final reversed in [false, true]) {
      testWidgets('chapter navigation layout $scenario reversed=$reversed', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(scenario.size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repaint = GlobalKey();
        final changes = ValueNotifier<int>(0);
        final controller = ReaderChapterNavigationController(
          onChanged: () => changes.value++,
        );
        final selected = <int>[];
        final request = ReaderChapterNavigationRequest(
          identity: Object(),
          isCurrent: () => true,
          canPrevious: true,
          canNext: true,
          reversed: reversed,
          select: selected.add,
        );
        controller.report(request, 1);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: scenario.dark ? Brightness.dark : Brightness.light,
                fontFamily: Platform.environment['FLOATING_NAV_QA_FONT'] == null
                    ? null
                    : 'FloatingNavigationQA',
              ),
              home: MediaQuery(
                data: MediaQueryData(
                  size: scenario.size,
                  textScaler: TextScaler.linear(scenario.scale),
                  disableAnimations: true,
                  padding: const EdgeInsets.only(
                    top: 24,
                    right: 24,
                    bottom: 32,
                  ),
                ),
                child: RepaintBoundary(
                  key: repaint,
                  child: Scaffold(
                    body: ValueListenableBuilder<int>(
                      valueListenable: changes,
                      builder: (_, _, _) => Stack(
                        fit: StackFit.expand,
                        children: [
                          const Center(child: Text('Reading a chapter')),
                          ReaderChapterNavigationButton(
                            action: controller.action,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final button = find.byTooltip('Next chapter');
          final rect = tester.getRect(button);
          expect(rect.size, const Size(58, 58));
          expect(rect.right, scenario.size.width - 40);
          expect(rect.bottom, scenario.size.height - 68);
          expect(
            find.byIcon(
              reversed
                  ? Icons.arrow_back_ios_outlined
                  : Icons.arrow_forward_ios,
            ),
            findsOneWidget,
          );
          final data = tester.getSemantics(button).getSemanticsData();
          expect(data.label + data.tooltip, contains('Next chapter'));
          expect(
            tester
                .widget<AnimatedPositioned>(find.byType(AnimatedPositioned))
                .duration,
            Duration.zero,
          );
          final colors = Theme.of(tester.element(button)).colorScheme;
          final a = colors.onPrimaryContainer.computeLuminance(),
              b = colors.primaryContainer.computeLuminance();
          expect(
            a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05),
            greaterThanOrEqualTo(3),
          );
          final output = Platform.environment['FLOATING_NAV_QA_DIR'];
          if (output != null) {
            await tester.runAsync(() async {
              final boundary =
                  repaint.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '$output/${scenario.size.width.toInt()}-${reversed ? 'rtl' : 'ltr'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(selected, [1]);
          expect(find.byType(IconButton).hitTestable(), findsNothing);
          expect(find.bySemanticsLabel('Next chapter'), findsNothing);
          expect(
            tester
                .widget<ExcludeFocus>(find.byType(ExcludeFocus).last)
                .excluding,
            true,
          );
          controller.report(request, -1);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Previous chapter'));
          await tester.pumpAndSettle();
          expect(selected, [1, -1]);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          changes.dispose();
        }
      });
    }
  }
}
