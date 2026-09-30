import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/action_button.dart';

Future<void> _pumpActionRow(WidgetTester tester, Widget action) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [action],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the full detail action row remains a labeled button target', (
    tester,
  ) async {
    var presses = 0;
    await _pumpActionRow(
      tester,
      ComicDetailActionButton(
        icon: const Icon(Icons.watch_later_outlined),
        text: 'Read later',
        onPressed: () => presses++,
      ),
    );

    final node = tester.getSemantics(find.text('Read later'));
    final data = node.getSemanticsData();
    expect(data.label, 'Read later');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(node.rect.height, greaterThanOrEqualTo(48));

    final bounds = tester.getRect(find.byType(ComicDetailActionButton));
    expect(bounds.height, 48);
    await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
    await tester.pump();
    expect(presses, 1, reason: 'The space above the outline must be tappable.');
    await tester.tapAt(Offset(bounds.center.dx, bounds.bottom - 1));
    await tester.pump();
    expect(presses, 2, reason: 'The space below the outline must be tappable.');
    await tester.tap(find.text('Read later'));
    await tester.pump();
    expect(presses, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail actions preserve keyboard activation and long press', (
    tester,
  ) async {
    var presses = 0;
    var longPresses = 0;
    await _pumpActionRow(
      tester,
      ComicDetailActionButton(
        icon: const Icon(Icons.bookmark_outline),
        text: 'Favorite',
        onPressed: () => presses++,
        onLongPressed: () => longPresses++,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester
          .getSemantics(find.text('Favorite'))
          .getSemanticsData()
          .flagsCollection
          .isFocused,
      Tristate.isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(presses, 2);

    await tester.longPress(find.text('Favorite'));
    await tester.pump();
    expect(longPresses, 1);
    expect(presses, 2, reason: 'A long press must not also perform a tap.');
  });

  testWidgets('loading disables semantics and every activation path', (
    tester,
  ) async {
    var loading = false;
    var presses = 0;
    var longPresses = 0;
    late StateSetter update;
    await _pumpActionRow(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return ComicDetailActionButton(
            icon: const Icon(Icons.favorite_border),
            text: 'Like',
            isLoading: loading,
            onPressed: () => presses++,
            onLongPressed: () => longPresses++,
          );
        },
      ),
    );

    // Disable an already focused action to catch stale keyboard callbacks.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    update(() => loading = true);
    await tester.pump();

    final data = tester.getSemantics(find.text('Like')).getSemanticsData();
    expect(data.label, 'Like');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.hasAction(SemanticsAction.longPress), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.text('Like'));
    await tester.pump();
    await tester.longPress(find.text('Like'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(presses, 0);
    expect(longPresses, 0);

    update(() => loading = false);
    await tester.pump();
    await tester.tap(find.text('Like'));
    await tester.pump();
    expect(presses, 1, reason: 'The action must become usable after loading.');
    expect(tester.takeException(), isNull);
  });
}
