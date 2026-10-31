import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/tv_navigation.dart';

Widget _app(Widget child, {bool enabled = true, ThemeData? theme}) =>
    MaterialApp(
      theme: theme,
      builder: (_, child) => TvNavigation(enabled: enabled, child: child!),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('TV directions and select activate a control exactly once', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _app(
        Row(
          children: [
            ClickInkWell(
              autofocus: true,
              onTap: () => calls.add('first'),
              child: const SizedBox(
                width: 100,
                height: 80,
                child: Text('first'),
              ),
            ),
            Button.filled(
              onPressed: () => calls.add('second'),
              child: const Text('second'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    expect(calls, ['first', 'second', 'second']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote activation does not repeat on a held select key', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        TvFocusable(
          autofocus: true,
          onPressed: () => calls++,
          child: const Text('activate'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(calls, 1);
  });

  testWidgets('disabled controls cannot be activated', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            TvFocusable(
              autofocus: true,
              onPressed: null,
              child: const Text('disabled'),
            ),
            TvFocusable(
              autofocus: true,
              onPressed: () => calls++,
              child: const Text('enabled'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(calls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(calls, 1);
  });

  testWidgets('focused list controls are scrolled into view', (tester) async {
    final nodes = List.generate(30, (_) => FocusNode());
    final scroll = ScrollController();
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
      scroll.dispose();
    });
    await tester.pumpWidget(
      _app(
        SizedBox(
          height: 200,
          child: ListView(
            controller: scroll,
            children: List.generate(
              30,
              (index) => ClickInkWell(
                focusNode: nodes[index],
                onTap: () {},
                child: SizedBox(height: 64, child: Text('item $index')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var index = 0; index <= 15; index++) {
      nodes[index].requestFocus();
      await tester.pumpAndSettle();
    }
    expect(scroll.offset, greaterThan(0));
    expect(find.text('item 15').hitTestable(), findsOneWidget);
  });

  testWidgets('modal closes and focus returns to the opening control', (
    tester,
  ) async {
    var selections = 0;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => ClickInkWell(
            autofocus: true,
            onTap: () {
              selections++;
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('modal'),
                  actions: [
                    TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('close'),
                    ),
                  ],
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('modal'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('modal'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selections, 2);
  });

  testWidgets('TV media policy does not change ordinary builds', (
    tester,
  ) async {
    for (final enabled in [false, true]) {
      late MediaQueryData media;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
          enabled: enabled,
        ),
      );
      expect(
        media.navigationMode,
        enabled ? NavigationMode.directional : NavigationMode.traditional,
      );
      expect(media.padding.left, enabled ? 24 : 0);
      expect(media.textScaler.scale(10), enabled ? 11 : 10);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'focus remains visible in $brightness with reduced motion and large text',
      (tester) async {
        await tester.pumpWidget(
          _app(
            MediaQuery(
              data: const MediaQueryData(
                textScaler: TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: ClickInkWell(
                autofocus: true,
                onTap: () {},
                child: const Text('focus'),
              ),
            ),
            theme: ThemeData(brightness: brightness),
          ),
        );
        await tester.pumpAndSettle();
        final decorations = tester.widgetList<DecoratedBox>(
          find.byType(DecoratedBox),
        );
        expect(
          decorations.any(
            (box) =>
                box.decoration is BoxDecoration &&
                (box.decoration as BoxDecoration).border?.top.width == 3,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
