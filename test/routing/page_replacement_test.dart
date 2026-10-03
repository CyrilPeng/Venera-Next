import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/routing/page_replacement.dart';

void main() {
  for (final nested in [false, true]) {
    testWidgets('replacement removes only original details; nested=$nested', (
      tester,
    ) async {
      final root = GlobalKey<NavigatorState>();
      final inner = GlobalKey<NavigatorState>();
      late BuildContext origin;
      const home = Scaffold(body: Text('Library'));
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: root,
          home: nested
              ? Navigator(
                  key: inner,
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => home),
                )
              : home,
        ),
      );
      final owner = nested ? inner.currentState! : root.currentState!;
      owner.push(
        MaterialPageRoute<void>(
          builder: (context) {
            origin = context;
            return const Scaffold(body: Text('Details'));
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        replaceWithRootPage(
          origin,
          (_) => const Scaffold(body: Text('Reader')),
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Reader'), findsOneWidget);
      if (nested) expect(inner.currentState!.canPop(), isFalse);
      root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Details'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('covered and disposed routes cannot redirect a newer page', (
    tester,
  ) async {
    final root = GlobalKey<NavigatorState>();
    late BuildContext origin;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: root,
        home: Builder(
          builder: (context) {
            origin = context;
            return const Scaffold();
          },
        ),
      ),
    );
    root.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('New page')),
      ),
    );
    await tester.pumpAndSettle();
    expect(replaceWithRootPage(origin, (_) => const Scaffold()), isFalse);
    expect(find.text('New page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(replaceWithRootPage(origin, (_) => const Scaffold()), isFalse);
  });
}
