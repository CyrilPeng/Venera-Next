import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/navigation_bar.dart';
import 'package:venera_next/foundation/app_page_route.dart';

class _TrackedAnimation extends AnimationController {
  _TrackedAnimation({required super.vsync}) : super(value: 0.5);
  final statusListeners = <AnimationStatusListener>{};
  @override
  void addStatusListener(AnimationStatusListener listener) {
    statusListeners.add(listener);
    super.addStatusListener(listener);
  }

  @override
  void removeStatusListener(AnimationStatusListener listener) {
    statusListeners.remove(listener);
    super.removeStatusListener(listener);
  }
}

void main() {
  test(
    'observer notifications tolerate listener removal and defer new listeners',
    () {
      final observer = NaviObserver();
      final calls = <String>[];
      void next() => calls.add('next');
      late VoidCallback first;
      first = () {
        calls.add('first');
        observer.removeListener(first);
        observer.addListener(next);
      };
      observer.addListener(first);
      observer.addListener(() => calls.add('second'));
      observer.notifyListeners();
      expect(calls, ['first', 'second']);
      observer.notifyListeners();
      expect(calls, ['first', 'second', 'second', 'next']);
    },
  );

  testWidgets('transition rebuilds do not retain curve status listeners', (
    tester,
  ) async {
    final primary = _TrackedAnimation(vsync: tester);
    final secondary = _TrackedAnimation(vsync: tester);
    final generation = ValueNotifier(0);
    final route = MaterialPageRoute<void>(
      builder: (_) => const SizedBox.shrink(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: generation,
          builder: (context, value, _) =>
              SlidePageTransitionBuilder().buildTransitions(
                route,
                context,
                primary,
                secondary,
                Text('frame $value'),
              ),
        ),
      ),
    );
    final initial = [
      primary.statusListeners.length,
      secondary.statusListeners.length,
    ];
    for (var i = 1; i <= 10; i++) {
      generation.value = i;
      await tester.pump();
      expect([
        primary.statusListeners.length,
        secondary.statusListeners.length,
      ], initial);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(primary.statusListeners, isEmpty);
    expect(secondary.statusListeners, isEmpty);
    primary.dispose();
    secondary.dispose();
    generation.dispose();
  });

  testWidgets(
    'replacing the nested navigator preserves only the new view callback',
    (tester) async {
      final pane = GlobalKey<NaviPaneState>();
      final observer = NaviObserver();
      final navigation = ValueNotifier(GlobalKey<NavigatorState>());
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<GlobalKey<NavigatorState>>(
            valueListenable: navigation,
            builder: (_, key, _) => NaviPane(
              key: pane,
              paneItems: [
                PaneItemEntry(
                  label: 'Home',
                  icon: Icons.home,
                  activeIcon: Icons.home,
                ),
              ],
              paneActions: const [],
              pageBuilder: (_) => const Text('content'),
              observer: observer,
              navigatorKey: key,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = pane.currentState!;
      final original = state.mainViewUpdateHandler;
      navigation.value = GlobalKey<NavigatorState>();
      await tester.pumpAndSettle();
      expect(state.mainViewUpdateHandler, isNotNull);
      expect(state.mainViewUpdateHandler, isNot(original));
      expect(observer.routes, hasLength(1));
      expect(
        observer.routes.single.navigator,
        same(navigation.value.currentState),
      );
      state.mainViewUpdateHandler!();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.mainViewUpdateHandler, isNull);
      navigation.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('replacing a pane observer detaches its previous subscription', (
    tester,
  ) async {
    final first = NaviObserver();
    final second = NaviObserver();
    final observer = ValueNotifier(first);
    final navigation = GlobalKey<NavigatorState>();
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<NaviObserver>(
          valueListenable: observer,
          builder: (_, value, _) => NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home,
                activeIcon: Icons.home,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => const Text('content'),
            observer: value,
            navigatorKey: navigation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    observer.value = second;
    await tester.pumpAndSettle();
    expect(first.listeners, isEmpty);
    expect(first.routes, isEmpty);
    expect(second.listeners, hasLength(1));
    expect(second.routes, hasLength(1));
    expect(second.routes.single.navigator, same(navigation.currentState));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.listeners, isEmpty);
    expect(second.routes, isEmpty);
    first.notifyListeners();
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing a covered route preserves observer stack order', (
    tester,
  ) async {
    final observer = NaviObserver();
    final navigation = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigation,
        navigatorObservers: [observer],
        home: const Text('home'),
      ),
    );
    final first = MaterialPageRoute<void>(builder: (_) => const Text('first'));
    final top = MaterialPageRoute<void>(builder: (_) => const Text('top'));
    navigation.currentState!.push(first);
    await tester.pumpAndSettle();
    navigation.currentState!.push(top);
    await tester.pumpAndSettle();
    final root = observer.routes.first;
    final replacement = MaterialPageRoute<void>(
      builder: (_) => const Text('replacement'),
    );
    navigation.currentState!.replace(oldRoute: first, newRoute: replacement);
    await tester.pumpAndSettle();
    expect(observer.routes.toList(), [root, replacement, top]);
    navigation.currentState!.pop();
    await tester.pumpAndSettle();
    expect(observer.routes.toList(), [root, replacement]);
    expect(find.text('replacement'), findsOneWidget);
  });
}
