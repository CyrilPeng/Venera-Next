import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/foundation/harmonyos.dart';

import '../support/ui_regression_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadUiRegressionFonts);
  setUp(() => HarmonyOS.debugIsCurrent = true);
  tearDown(() => HarmonyOS.debugIsCurrent = null);

  for (final scenario in [
    (size: const Size(375, 667), width: 343.0, scale: 1.0, dark: false),
    (size: const Size(375, 667), width: 343.0, scale: 3.2, dark: true),
    (size: const Size(667, 375), width: 140.0, scale: 2.0, dark: true),
    (size: const Size(1024, 768), width: 400.0, scale: 1.0, dark: false),
  ]) {
    for (final longName in [false, true]) {
      testWidgets(
        'selector fits its local width and aligns its arrow at $scenario, long=$longName',
        (tester) async {
          tester.view.physicalSize = scenario.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          final label = longName
              ? 'Reading / A folder with a very long name'
              : 'Reading';
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  brightness: scenario.dark
                      ? Brightness.dark
                      : Brightness.light,
                  fontFamily: uiRegressionFont,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: scenario.width,
                      child: Select(
                        current: label,
                        values: [label],
                        minWidth: 112,
                        menuBuilder: (_, _) => const SizedBox(),
                        onTap: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final selector = tester.getRect(find.byType(Select));
          final arrow = tester.getRect(find.byIcon(Icons.arrow_drop_down));
          final text = tester.getRect(find.text(label));
          expect(selector.width, scenario.width);
          expect(selector.height, greaterThanOrEqualTo(48));
          expect(text.overlaps(arrow), isFalse);
          expect(text.left, greaterThanOrEqualTo(selector.left));
          expect(arrow.right, closeTo(selector.right - 13, 1));
          await captureUiRegression(
            tester,
            boundary,
            'select-${scenario.size.width.toInt()}-${scenario.width.toInt()}-${scenario.scale}-$longName',
          );
        },
      );
    }
  }

  testWidgets(
    'a loose selector keeps its natural width beside another control',
    (tester) async {
      HarmonyOS.debugIsCurrent = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Select(current: 'One', values: const ['One'], onTap: (_) {}),
                const SizedBox(width: 16),
                const Text('Another control'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final selector = tester.getRect(find.byType(Select));
      final other = tester.getRect(find.text('Another control'));
      expect(selector.right, lessThan(other.left));
      expect(selector.width, lessThan(200));
    },
  );

  for (final alert in [false, true]) {
    for (final scenario in [
      (size: const Size(375, 667), scale: 1.0),
      (size: const Size(667, 375), scale: 2.0),
      (size: const Size(1024, 768), scale: 3.2),
    ]) {
      testWidgets(
        'selector measures and changes in an intrinsic dialog; alert=$alert, $scenario',
        (tester) async {
          tester.view.physicalSize = scenario.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const values = ['Reading / A folder with a very long name', 'Other'];
          var selected = values.first;
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scenario.scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => StatefulBuilder(
                        builder: (context, setState) {
                          final content = Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Select(
                                current: selected,
                                values: values,
                                onTap: (index) =>
                                    setState(() => selected = values[index]),
                              ),
                            ],
                          );
                          return alert
                              ? AlertDialog(content: content)
                              : ContentDialog(
                                  content: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: content,
                                  ),
                                );
                        },
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final selector = tester.getRect(find.byType(Select));
          final dialog = tester.getRect(find.byType(Dialog));
          final arrow = tester.getRect(find.byIcon(Icons.arrow_drop_down));
          final label = tester.getRect(find.text(selected));
          expect(selector.left, greaterThanOrEqualTo(dialog.left));
          expect(selector.right, lessThanOrEqualTo(dialog.right));
          expect(label.overlaps(arrow), isFalse);
          expect(arrow.right, closeTo(selector.right - 13, 1));

          await tester.tap(find.byType(Select));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Other'));
          await tester.pumpAndSettle();
          expect(selected, 'Other');
          expect(find.text('Other'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
