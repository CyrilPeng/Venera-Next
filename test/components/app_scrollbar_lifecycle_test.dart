import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/scroll.dart';

class _Controller extends ScrollController {
  _Controller({super.initialScrollOffset}) : super(keepScrollOffset: false);
  final listeners = <VoidCallback>{};
  int disposals = 0;
  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

Widget _host(
  ScrollController controller, {
  Key? listKey,
  int items = 100,
  int clients = 1,
  double height = 500,
  bool fixedContent = false,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 300,
      height: height,
      child: AppScrollBar(
        controller: controller,
        child: clients == 0
            ? const SizedBox()
            : fixedContent
            ? SingleChildScrollView(
                controller: controller,
                child: SizedBox(height: items * 80.0),
              )
            : Column(
                children: List.generate(
                  clients,
                  (i) => Expanded(
                    child: ListView.builder(
                      key: listKey,
                      controller: controller,
                      itemExtent: 80,
                      itemCount: items,
                      itemBuilder: (_, index) => Text('Item $index'),
                    ),
                  ),
                ),
              ),
      ),
    ),
  ),
);

Finder get _thumb => find.byIcon(Icons.arrow_drop_up);

Future<TestGesture> _startDrag(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(_thumb));
  await gesture.moveBy(const Offset(0, 25));
  await tester.pump();
  await gesture.moveBy(const Offset(0, 25));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets(
    'replacement detaches old listener and borrows the new controller',
    (tester) async {
      final old = _Controller(),
          current = _Controller(initialScrollOffset: 400);
      addTearDown(old.dispose);
      addTearDown(current.dispose);
      await tester.pumpWidget(_host(old));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(AppScrollBar));
      await tester.pumpWidget(_host(current));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(AppScrollBar)), same(state));
      expect(old.listeners, isEmpty);
      final before = tester.getCenter(_thumb).dy;
      current.jumpTo(1500);
      await tester.pump();
      expect(tester.getCenter(_thumb).dy, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
      expect(current.listeners, isEmpty);
      expect(old.disposals + current.disposals, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a drag cannot continue into a replacement controller', (
    tester,
  ) async {
    final old = _Controller(), current = _Controller(initialScrollOffset: 300);
    addTearDown(old.dispose);
    addTearDown(current.dispose);
    await tester.pumpWidget(_host(old));
    await tester.pumpAndSettle();
    final gesture = await _startDrag(tester);
    expect(old.offset, greaterThan(0));
    await tester.pumpWidget(_host(current));
    await tester.pump();
    // Scrollable transfers its position when only the controller changes.
    final replacementOffset = current.offset;
    await gesture.moveBy(const Offset(0, 45));
    await tester.pump();
    expect(current.offset, replacementOffset);
    await gesture.up();
    await tester.pumpAndSettle();
    final next = await _startDrag(tester);
    expect(current.offset, greaterThan(replacementOffset));
    await next.up();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('same controller replacement viewport retires an ongoing drag', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, listKey: const ValueKey('old')));
    await tester.pumpAndSettle();
    final original = controller.position;
    final gesture = await _startDrag(tester);
    expect(controller.offset, greaterThan(0));
    await tester.pumpWidget(_host(controller, listKey: const ValueKey('new')));
    await tester.pump();
    expect(controller.position, isNot(same(original)));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(controller.offset, 0);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('content metrics update the thumb without a scroll event', (
    tester,
  ) async {
    final controller = _Controller(initialScrollOffset: 1000);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, items: 30, fixedContent: true));
    await tester.pumpAndSettle();
    final before = tester.getCenter(_thumb).dy;
    final original = controller.position;
    await tester.pumpWidget(_host(controller, items: 100, fixedContent: true));
    await tester.pumpAndSettle();
    expect(controller.position, same(original));
    expect(controller.offset, 1000);
    expect(controller.position.maxScrollExtent, 7500);
    expect(tester.getCenter(_thumb).dy, lessThan(before));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  for (final clients in [0, 2]) {
    testWidgets('ambiguous or missing viewport hides the thumb: $clients', (
      tester,
    ) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, clients: clients));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_thumb, findsNothing);
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();
      expect(_thumb, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(controller.disposals, 0);
    });
  }

  testWidgets('too-short track has no invalid drag target', (tester) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller, height: 20));
    await tester.pumpAndSettle();
    expect(_thumb, findsNothing);
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmount during hover and drag cancels delayed work', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(controller));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(_thumb));
    final drag = await _startDrag(tester);
    await tester.pumpWidget(const SizedBox());
    await drag.up();
    await mouse.removePointer();
    await tester.pump(const Duration(seconds: 3));
    expect(controller.listeners, isEmpty);
    expect(controller.disposals, 0);
    expect(tester.takeException(), isNull);
  });
}
