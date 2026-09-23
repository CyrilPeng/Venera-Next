import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  testWidgets(
    'evaluator awaits promises, formats results and exposes async errors',
    (tester) async {
      final oldLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'en-US';
      addTearDown(() => appdata.settings['language'] = oldLanguage);
      var response = Completer<Object?>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DebugPage(
              evaluate: (_) {
                calls++;
                return response.future;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Run'));
      await tester.pump();
      expect(find.text('Run'), findsNothing);
      expect(calls, 1);
      response.complete({'chapters': 3});
      await tester.pump();
      expect(find.text('{\n  "chapters": 3\n}'), findsOneWidget);
      response = Completer<Object?>();
      await tester.tap(find.text('Run'));
      response.completeError('source parse failed');
      await tester.pump();
      expect(find.text('source parse failed'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget);
    },
  );

  testWidgets('late evaluator results after leaving the page are safe', (
    tester,
  ) async {
    final response = Completer<Object?>();
    final key = GlobalKey<DebugPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebugPage(key: key, evaluate: (_) => response.future),
        ),
      ),
    );
    final running = key.currentState!.run();
    await tester.pumpWidget(const SizedBox());
    response.complete('late');
    await running;
    expect(tester.takeException(), isNull);
  });
}
