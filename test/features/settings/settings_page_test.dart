import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';

void main() {
  testWidgets('settings lists reading statistics as a top-level entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));

    expect(find.text('Reading statistics'), findsOneWidget);
    expect(find.byIcon(Icons.query_stats), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
