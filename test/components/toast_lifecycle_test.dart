import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';

void main() {
  testWidgets('overlay child replacement appears without a new host', (
    tester,
  ) async {
    final key = GlobalKey<OverlayWidgetState>();
    Widget host(String text) =>
        MaterialApp(home: OverlayWidget(Text(text), key: key));
    await tester.pumpWidget(host('Original content'));
    final original = key.currentState!;
    original.showToast(message: 'Active notice', seconds: 5);
    await tester.pump();
    await tester.pumpWidget(host('Replacement content'));
    expect(key.currentState, same(original));
    expect(find.text('Replacement content'), findsOneWidget);
    expect(find.text('Original content'), findsNothing);
    expect(find.text('Active notice'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlay host releases its owned initial entry on removal', (
    tester,
  ) async {
    final key = GlobalKey<OverlayWidgetState>();
    await tester.pumpWidget(
      MaterialApp(home: OverlayWidget(const SizedBox(), key: key)),
    );
    final entry = tester
        .widget<Overlay>(find.byKey(key.currentState!.overlayKey))
        .initialEntries
        .single;
    var changes = 0;
    entry.addListener(() => changes++);
    await tester.pumpWidget(const SizedBox());
    expect(entry.mounted, isFalse);
    expect(() => entry.addListener(() {}), throwsAssertionError);
    expect(changes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired or removed notices cannot remove a later notice', (
    tester,
  ) async {
    final key = GlobalKey<OverlayWidgetState>();
    await tester.pumpWidget(
      MaterialApp(home: OverlayWidget(const Text('Page'), key: key)),
    );
    final owner = key.currentState!;
    owner.showToast(message: 'Old notice', seconds: 1);
    await tester.pump();
    owner.removeAll();
    owner.showToast(message: 'Current notice', seconds: 3);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Old notice'), findsNothing);
    expect(find.text('Current notice'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Current notice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    owner.showToast(message: 'Late notice');
    expect(tester.takeException(), isNull);
  });

  testWidgets('notice can expire before its first frame', (tester) async {
    final key = GlobalKey<OverlayWidgetState>();
    await tester.pumpWidget(
      MaterialApp(home: OverlayWidget(const Text('Page'), key: key)),
    );
    key.currentState!.showToast(message: 'Immediate notice', seconds: 0);
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(find.text('Immediate notice'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
