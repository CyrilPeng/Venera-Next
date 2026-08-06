import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/history.dart';

void main() {
  testWidgets('reading stats summary keeps the tracked label on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReadingStatsSummary(
            totalDuration: Duration(hours: 12, minutes: 36),
            comicCount: 18,
            mostReadTitle: 'A very long comic title used for compact layout',
          ),
        ),
      ),
    );

    final labelSize = tester.getSize(find.text('Comics tracked'));
    expect(labelSize.height, lessThan(24));
    expect(tester.takeException(), isNull);
  });
}
