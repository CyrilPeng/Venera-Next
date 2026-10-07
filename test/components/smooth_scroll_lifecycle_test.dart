import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/scroll.dart';

class _BorrowedController extends ScrollController {
  _BorrowedController({super.initialScrollOffset});
  int disposals = 0;
  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

const _surface = ValueKey('wheel-surface');

Widget _host({
  ScrollController? controller,
  void Function(ScrollController)? capture,
  bool attach = true,
  Key? listKey,
  Axis axis = Axis.vertical,
}) => MaterialApp(
  home: SmoothScrollProvider(
    controller: controller,
    builder: (_, current, physics) {
      capture?.call(current);
      return SizedBox.expand(
        key: _surface,
        child: attach
            ? ListView.builder(
                key: listKey,
                controller: current,
                physics: physics,
                scrollDirection: axis,
                itemCount: 100,
                itemExtent: 80,
                itemBuilder: (_, i) => Text('Item $i'),
              )
            : const ColoredBox(color: Colors.white),
      );
    },
  ),
);

Future<void> _wheel(WidgetTester tester, double delta, {Offset? at}) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: at ?? tester.getCenter(find.byKey(_surface)),
      scrollDelta: Offset(0, delta),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('provider releases its fallback controller on unmount', (
    tester,
  ) async {
    late ScrollController owned;
    await tester.pumpWidget(_host(capture: (c) => owned = c));
    expect(owned.hasClients, true);
    await tester.pumpWidget(const SizedBox());
    expect(() => owned.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same provider follows replacement borrowed controllers', (
    tester,
  ) async {
    final first = _BorrowedController();
    final second = _BorrowedController(initialScrollOffset: 240);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late ScrollController current;
    await tester.pumpWidget(
      _host(controller: first, capture: (c) => current = c),
    );
    final state = tester.state(find.byType(SmoothScrollProvider));
    await tester.pumpWidget(
      _host(controller: second, capture: (c) => current = c),
    );
    expect(tester.state(find.byType(SmoothScrollProvider)), same(state));
    expect(current, same(second));
    expect(first.hasClients, false);
    expect(second.hasClients, true);
    second.jumpTo(320);
    await tester.pump();
    expect(second.offset, 320);
    await tester.pumpWidget(const SizedBox());
    expect(first.disposals, 0);
    expect(second.disposals, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback and borrowed transitions preserve ownership', (
    tester,
  ) async {
    final borrowed = _BorrowedController();
    addTearDown(borrowed.dispose);
    late ScrollController current;
    await tester.pumpWidget(_host(capture: (c) => current = c));
    final firstOwned = current;
    await tester.pumpWidget(
      _host(controller: borrowed, capture: (c) => current = c),
    );
    expect(current, same(borrowed));
    expect(() => firstOwned.addListener(() {}), throwsFlutterError);
    await tester.pumpWidget(_host(capture: (c) => current = c));
    expect(current, isNot(same(firstOwned)));
    expect(current, isNot(same(borrowed)));
    final lastOwned = current;
    await tester.pumpWidget(const SizedBox());
    expect(() => lastOwned.addListener(() {}), throwsFlutterError);
    expect(borrowed.disposals, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wheel with no attached viewport is ignored', (tester) async {
    await tester.pumpWidget(_host(attach: false));
    await _wheel(tester, 120);
    expect(tester.takeException(), isNull);
  }, skip: Platform.isMacOS);

  testWidgets(
    'removing a scrolling provider ignores animation completion',
    (tester) async {
      final controller = _BorrowedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller: controller));
      await _wheel(tester, 160);
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.offset, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(controller.disposals, 0);
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );

  testWidgets(
    'detaching a viewport while the provider survives is safe',
    (tester) async {
      final controller = _BorrowedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller: controller));
      await _wheel(tester, 160);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(_host(controller: controller, attach: false));
      await tester.pumpAndSettle();
      expect(controller.hasClients, false);
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );

  testWidgets(
    'new viewport starts wheel accumulation from its own position',
    (tester) async {
      final controller = _BorrowedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller: controller));
      await _wheel(tester, 400);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(_host(controller: controller, attach: false));
      await tester.pump();
      await tester.pumpWidget(
        _host(controller: controller, listKey: const ValueKey('replacement')),
      );
      controller.jumpTo(0);
      await _wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(100, .01));
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );

  testWidgets(
    'replacing the borrowed controller during wheel animation keeps new input',
    (tester) async {
      final first = _BorrowedController();
      final second = _BorrowedController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(_host(controller: first));
      await _wheel(tester, 400);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(_host(controller: second));
      second.jumpTo(0);
      await _wheel(tester, 100);
      await _wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(second.offset, closeTo(206.25, .01));
      expect(first.hasClients, false);
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );

  for (final axis in Axis.values) {
    testWidgets('wheel burst, bounds and Shift behavior on $axis', (
      tester,
    ) async {
      final controller = _BorrowedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller: controller, axis: axis));
      await _wheel(tester, 100);
      await _wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(206.25, .01));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, 100);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(206.25, .01));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, 100000);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      await _wheel(tester, -100000);
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.minScrollExtent);
      expect(tester.takeException(), isNull);
    }, skip: Platform.isMacOS);
  }

  testWidgets(
    'ambiguous shared controller does not move either viewport',
    (tester) async {
      final controller = _BorrowedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SmoothScrollProvider(
            controller: controller,
            builder: (_, current, physics) => Row(
              key: _surface,
              children: [
                for (var i = 0; i < 2; i++)
                  Expanded(
                    child: ListView.builder(
                      controller: current,
                      physics: physics,
                      itemCount: 100,
                      itemExtent: 80,
                      itemBuilder: (_, i) => Text('Item $i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      expect(controller.positions, hasLength(2));
      await _wheel(tester, 100, at: const Offset(100, 100));
      await tester.pumpAndSettle();
      expect(controller.positions.map((p) => p.pixels), everyElement(0));
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );

  testWidgets(
    'moving a hovered child releases the old parent wheel block',
    (tester) async {
      final first = _BorrowedController();
      final second = _BorrowedController();
      final child = _BorrowedController();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(child.dispose);
      final childKey = GlobalKey();
      Widget host(bool inFirst) {
        Widget region(ScrollController controller, bool containsChild) =>
            Expanded(
              child: SmoothScrollProvider(
                controller: controller,
                builder: (_, current, physics) => Stack(
                  children: [
                    ListView.builder(
                      controller: current,
                      physics: physics,
                      itemExtent: 80,
                      itemCount: 100,
                      itemBuilder: (_, i) => Text('Parent $i'),
                    ),
                    if (containsChild)
                      Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 160,
                          height: 100,
                          child: SmoothScrollProvider(
                            key: childKey,
                            controller: child,
                            builder: (_, current, physics) => ListView.builder(
                              controller: current,
                              physics: physics,
                              itemExtent: 40,
                              itemCount: 100,
                              itemBuilder: (_, i) => Text('Child $i'),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
        return MaterialApp(
          home: Column(
            children: [region(first, inFirst), region(second, !inFirst)],
          ),
        );
      }

      await tester.pumpWidget(host(true));
      final state = childKey.currentState;
      final at = tester.getCenter(find.byKey(childKey));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: at);
      await tester.pump();
      await _wheel(tester, 100, at: at);
      await tester.pumpAndSettle();
      expect(child.offset, closeTo(100, .01));
      expect(first.offset, 0);
      await tester.pumpWidget(host(false));
      await tester.pump();
      expect(childKey.currentState, same(state));
      await _wheel(tester, 100, at: at);
      await tester.pumpAndSettle();
      expect(first.offset, closeTo(100, .01));
      expect(second.offset, 0);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isMacOS,
  );
}
