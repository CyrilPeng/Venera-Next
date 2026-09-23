import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_script_editor.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  setUp(() {
    // Cached asset futures otherwise retain the previous widget test's zone.
    rootBundle.clear();
    final previous = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = previous);
  });

  testWidgets(
    'save reports failures, retries edited text and prevents duplicate saves',
    (tester) async {
      var response = Completer<void>();
      final saves = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SourceScriptEditor(
            script: 'original',
            onSave: (script) {
              saves.add(script);
              return response.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await waitForEditor(tester);
      await tester.enterText(find.byType(TextField), 'broken');
      await tester.tap(find.text('Save and reload'));
      await tester.pump();
      expect(find.text('Save and reload'), findsNothing);
      expect(saves, ['broken']);
      response.completeError('script.js:7: invalid data');
      await tester.pumpAndSettle();
      expect(find.text('script.js:7: invalid data'), findsOneWidget);
      response = Completer<void>();
      await tester.enterText(find.byType(TextField), 'fixed');
      await tester.tap(find.text('Save and reload'));
      response.complete();
      await tester.pumpAndSettle();
      expect(saves, ['broken', 'fixed']);
      expect(find.text('Source reloaded'), findsOneWidget);
    },
  );

  testWidgets(
    'leaving a dirty script offers to keep edits or discard without saving',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SourceScriptEditor(
            script: 'original',
            onSave: (_) async {
              saves++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await waitForEditor(tester);
      await tester.enterText(find.byType(TextField), 'unsaved');
      await tester.pump();
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('unsaved'), findsOneWidget);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceScriptEditor), findsNothing);
      expect(saves, 0);
    },
  );

  for (final size in [const Size(360, 640), const Size(800, 360)]) {
    testWidgets(
      'long errors stay scrollable at $size with dark theme and large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: SourceScriptEditor(
              script: 'source',
              onSave: (_) async =>
                  throw List.filled(100, 'Error: source.js:123').join('\n'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await waitForEditor(tester);
        await tester.tap(find.text('Save and reload'));
        await tester.pumpAndSettle();
        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.getSize(find.byType(TextField)).height, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> waitForEditor(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    if (find.byType(TextField).evaluate().isNotEmpty) return;
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }
  fail('The syntax highlighter did not finish loading.');
}
