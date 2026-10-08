import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_page_route.dart';
import 'package:venera_next/foundation/edge_back_gesture.dart';

void main() {
  var starts = 0;
  var ends = 0;
  var cancels = 0;
  var childDrags = 0;
  var progress = 0.0;

  Future<void> mount(
    WidgetTester tester, {
    bool enabled = true,
    bool scrollable = false,
  }) async {
    starts = ends = cancels = childDrags = 0;
    progress = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: EdgeBackGestureDetector(
          enabled: () => enabled,
          onStart: () => starts++,
          onUpdate: (delta) => progress += delta,
          onEnd: (_) => ends++,
          onCancel: () => cancels++,
          child: GestureDetector(
            onHorizontalDragUpdate: scrollable ? (_) => childDrags++ : null,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
  }

  testWidgets('edge back swipe works over horizontally scrollable content', (
    tester,
  ) async {
    await mount(tester, scrollable: true);
    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    expect(starts, 1);
    expect(ends, 1);
    expect(childDrags, 0);
  });

  testWidgets('removing an accepted edge gesture cancels it once', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(const Offset(5, 200));
    await gesture.moveBy(const Offset(100, 0));
    expect(starts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await gesture.up();
    expect(cancels, 1);
    expect(ends, 0);
  });

  for (final finishPointer in [false, true]) {
    testWidgets(
      'detaching iOS swipe owner ends navigator gesture; released=$finishPointer',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = finishPointer
            ? const Size(812, 375)
            : const Size(375, 812);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final navigator = GlobalKey<NavigatorState>();
        final visible = ValueNotifier(true);
        final animation = AnimationController(vsync: tester, value: 1);
        addTearDown(visible.dispose);
        addTearDown(animation.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: finishPointer ? Brightness.dark : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: finishPointer,
                textScaler: TextScaler.linear(finishPointer ? 3 : 1),
              ),
              child: child!,
            ),
            navigatorKey: navigator,
            home: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, show, _) => show
                  ? IOSBackGestureDetector(
                      enabledCallback: () => true,
                      gestureWidth: 24,
                      onStartPopGesture: () => IOSBackGestureController(
                        animation,
                        navigator.currentState!,
                        route: ModalRoute.of(context)!,
                      ),
                      child: const ColoredBox(color: Colors.white),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        );
        final gesture = await tester.startGesture(const Offset(5, 200));
        await gesture.moveBy(const Offset(200, 0));
        expect(navigator.currentState!.userGestureInProgress, isTrue);
        if (finishPointer) await gesture.cancel();
        visible.value = false;
        await tester.pump();
        if (!finishPointer) await gesture.up();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late drag completion cannot pop a newer route', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    final original = MaterialPageRoute<void>(
      builder: (_) => const Text('original'),
    );
    navigator.currentState!.push(original);
    await tester.pumpAndSettle();
    final animation = AnimationController(vsync: tester, value: 0.3);
    final gesture = IOSBackGestureController(
      animation,
      navigator.currentState!,
      route: original,
    );
    final newer = MaterialPageRoute<void>(builder: (_) => const Text('newer'));
    navigator.currentState!.push(newer);
    await tester.pumpAndSettle();
    gesture.dragEnd(2);
    await tester.pumpAndSettle();
    expect(newer.isCurrent, isTrue);
    expect(original.isActive, isTrue);
    expect(animation.value, 1);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    gesture.dispose();
    animation.dispose();
  });

  testWidgets('released gestures cannot stop another accepted gesture', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late Route<dynamic> route;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) {
            route = ModalRoute.of(context)!;
            return const Text('home');
          },
        ),
      ),
    );
    final firstAnimation = AnimationController(vsync: tester, value: 1);
    final secondAnimation = AnimationController(vsync: tester, value: 1);
    final first = IOSBackGestureController(
      firstAnimation,
      navigator.currentState!,
      route: route,
    );
    final second = IOSBackGestureController(
      secondAnimation,
      navigator.currentState!,
      route: route,
    );
    first.dispose();
    first.dispose();
    first.dragEnd(2);
    first.dragUpdate(1);
    await tester.pump();
    expect(navigator.currentState!.userGestureInProgress, isTrue);
    expect(firstAnimation.value, 1);
    second.dragEnd(0, cancelled: true);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    firstAnimation.dispose();
    secondAnimation.dispose();
  });

  testWidgets(
    'removing the navigator during a swipe releases without late errors',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final animation = AnimationController(vsync: tester, value: 1);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => IOSBackGestureDetector(
              enabledCallback: () => true,
              gestureWidth: 24,
              onStartPopGesture: () => IOSBackGestureController(
                animation,
                navigator.currentState!,
                route: ModalRoute.of(context)!,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(5, 200));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pumpWidget(const SizedBox.shrink());
      animation.dispose();
      await gesture.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('middle swipe stays with child horizontal gestures', (
    tester,
  ) async {
    await mount(tester, scrollable: true);
    await tester.dragFrom(const Offset(200, 200), const Offset(400, 0));
    expect(starts, 0);
    expect(childDrags, greaterThan(0));
  });

  testWidgets(
    'short, vertical, reverse and disabled edge gestures do not start',
    (tester) async {
      await mount(tester);
      for (final delta in [
        const Offset(10, 0),
        const Offset(20, 150),
        const Offset(-80, 0),
      ]) {
        await tester.dragFrom(const Offset(20, 200), delta);
      }
      expect(starts, 0);
      await mount(tester, enabled: false, scrollable: true);
      await tester.dragFrom(const Offset(5, 200), const Offset(400, 0));
      expect(starts, 0);
      expect(childDrags, greaterThan(0));
    },
  );

  testWidgets(
    'edge swipe starts after threshold and cleans up actual pointer IDs',
    (tester) async {
      await mount(tester);
      for (final pointer in [17, 42]) {
        final gesture = await tester.startGesture(
          const Offset(5, 200),
          pointer: pointer,
        );
        await gesture.moveBy(const Offset(12, 0));
        expect(starts, pointer == 17 ? 0 : 1);
        await gesture.moveBy(const Offset(80, 0));
        await gesture.up();
      }
      expect(starts, 2);
      expect(ends, 2);
      expect(progress, closeTo(184 / 800, 0.001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'second finger cancels active swipe and cannot restart until all fingers lift',
    (tester) async {
      await mount(tester);
      final first = await tester.startGesture(const Offset(5, 200), pointer: 7);
      await first.moveBy(const Offset(100, 0));
      final second = await tester.startGesture(
        const Offset(6, 300),
        pointer: 8,
      );
      await second.moveBy(const Offset(100, 0));
      await first.up();
      await second.up();
      expect(starts, 1);
      expect(cancels, 1);
      expect(ends, 0);
      await tester.dragFrom(const Offset(5, 200), const Offset(100, 0));
      expect(starts, 2);
      expect(ends, 1);
    },
  );

  testWidgets('cancel after halfway restores the route instead of popping it', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('home')),
    );
    final route = MaterialPageRoute<void>(builder: (_) => const Text('detail'));
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    final animation = AnimationController(vsync: tester, value: 1);
    final controller = IOSBackGestureController(
      animation,
      navigator.currentState!,
      route: route,
    );
    controller.dragUpdate(0.7);
    controller.dragEnd(0, cancelled: true);
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(animation.value, 1);
    expect(navigator.currentState!.userGestureInProgress, isFalse);
    animation.dispose();
  });
}
