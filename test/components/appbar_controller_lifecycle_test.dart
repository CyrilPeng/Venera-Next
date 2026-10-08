import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/appbar.dart';

class _TrackedAnimation extends Animation<double> {
  _TrackedAnimation(this.delegate);
  final Animation<double> delegate;
  final listeners = <VoidCallback, int>{};
  int get listenerCount => listeners.values.fold(0, (a, b) => a + b);
  @override
  double get value => delegate.value;
  @override
  AnimationStatus get status => delegate.status;
  @override
  void addListener(VoidCallback listener) {
    listeners.update(listener, (count) => count + 1, ifAbsent: () => 1);
    delegate.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    final count = listeners[listener] ?? 0;
    if (count <= 1) {
      listeners.remove(listener);
    } else {
      listeners[listener] = count - 1;
    }
    delegate.removeListener(listener);
  }

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      delegate.addStatusListener(listener);
  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      delegate.removeStatusListener(listener);
}

class _TrackedTabs extends TabController {
  _TrackedTabs({
    required super.length,
    required super.vsync,
    super.initialIndex,
  }) {
    observed = _TrackedAnimation(super.animation!);
  }
  late final _TrackedAnimation observed;
  final listeners = <VoidCallback, int>{};
  int get listenerCount => listeners.values.fold(0, (a, b) => a + b);
  @override
  Animation<double> get animation => observed;
  @override
  void addListener(VoidCallback listener) {
    listeners.update(listener, (count) => count + 1, ifAbsent: () => 1);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    final count = listeners[listener] ?? 0;
    if (count <= 1) {
      listeners.remove(listener);
    } else {
      listeners[listener] = count - 1;
    }
    super.removeListener(listener);
  }
}

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);

Widget _tabs(TabController controller) => Column(
  children: [
    AppTabBar(
      controller: controller,
      tabs: [for (var i = 0; i < controller.length; i++) Tab(text: 'Tab $i')],
    ),
    Expanded(
      child: TabViewBody(
        controller: controller,
        children: [for (var i = 0; i < controller.length; i++) Text('Body $i')],
      ),
    ),
  ],
);

Widget _search(SearchBarController controller, bool sliver, {Key? key}) =>
    sliver
    ? CustomScrollView(
        key: key,
        slivers: [SliverSearchBar(controller: controller)],
      )
    : AppSearchBar(key: key, controller: controller);

void main() {
  testWidgets(
    'inherited controller replacement updates both tab owner widgets',
    (tester) async {
      Widget show(int count) => _host(
        DefaultTabController(
          length: count,
          child: Column(
            children: [
              AppTabBar(
                tabs: [for (var i = 0; i < count; i++) Tab(text: 'Tab $i')],
              ),
              Expanded(
                child: TabViewBody(
                  children: [for (var i = 0; i < count; i++) Text('Body $i')],
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(show(2));
      final state = tester.state(find.byType(AppTabBar));
      final old = DefaultTabController.of(
        tester.element(find.byType(AppTabBar)),
      );
      old.index = 1;
      await tester.pumpAndSettle();
      expect(find.text('Body 1'), findsOneWidget);
      await tester.pumpWidget(show(3));
      final next = DefaultTabController.of(
        tester.element(find.byType(AppTabBar)),
      );
      expect(next, isNot(same(old)));
      expect(tester.state(find.byType(AppTabBar)), same(state));
      next.index = 2;
      await tester.pumpAndSettle();
      expect(find.text('Body 2'), findsOneWidget);
      await tester.pumpWidget(show(1));
      await tester.pumpAndSettle();
      expect(find.text('Body 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial page storage restores selection without overriding a replacement controller',
    (tester) async {
      final first = _TrackedTabs(length: 2, vsync: tester);
      final next = _TrackedTabs(length: 2, vsync: tester);
      final bucket = PageStorageBucket();
      addTearDown(first.dispose);
      addTearDown(next.dispose);
      Widget show(TabController? controller) => _host(
        PageStorage(
          bucket: bucket,
          child: controller == null
              ? const SizedBox.shrink()
              : AppTabBar(
                  key: const PageStorageKey('tabs'),
                  controller: controller,
                  tabs: const [
                    Tab(text: 'First'),
                    Tab(text: 'Second'),
                  ],
                ),
        ),
      );
      await tester.pumpWidget(show(first));
      first.index = 1;
      await tester.pumpAndSettle();
      await tester.pumpWidget(show(null));
      first.index = 0;
      await tester.pumpWidget(show(first));
      await tester.pumpAndSettle();
      expect(first.index, 1);
      await tester.pumpWidget(show(next));
      await tester.pumpAndSettle();
      expect(next.index, 0);
      expect(first.observed.listenerCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, brightness, scale) in [
    (const Size(375, 812), Brightness.dark, 2.0),
    (const Size(812, 375), Brightness.light, 1.0),
  ]) {
    testWidgets(
      'selected tab stays visible after selection and relayout at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = _TrackedTabs(length: 8, vsync: tester);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _host(_tabs(controller), brightness: brightness, scale: scale),
        );
        controller.index = 7;
        await tester.pumpAndSettle();
        expect(find.text('Body 7'), findsOneWidget);
        final selected = tester.getRect(find.text('Tab 7'));
        final viewport = tester.getRect(find.byType(SingleChildScrollView));
        expect(selected.left, greaterThanOrEqualTo(viewport.left));
        expect(selected.right, lessThanOrEqualTo(viewport.right));
        await tester.pumpWidget(
          _host(
            _tabs(controller),
            brightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.index, 7);
        expect(find.text('Body 7'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(controller.observed.listenerCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'dependency rebuilds do not duplicate tab listeners and removal releases owned scrolling',
    (tester) async {
      final controller = _TrackedTabs(length: 2, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(_tabs(controller)));
      final initial = controller.observed.listenerCount;
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      for (final brightness in [
        Brightness.dark,
        Brightness.light,
        Brightness.dark,
      ]) {
        await tester.pumpWidget(
          _host(_tabs(controller), brightness: brightness),
        );
        await tester.pumpAndSettle();
        expect(controller.observed.listenerCount, initial);
        expect(controller.listenerCount, 1);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(controller.observed.listenerCount, 0);
      expect(controller.listenerCount, 0);
      expect(() => scroll.addListener(() {}), throwsFlutterError);
      controller.animateTo(1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'controller replacement selects the new body and detaches the retired controller',
    (tester) async {
      final old = _TrackedTabs(length: 2, vsync: tester);
      final next = _TrackedTabs(length: 2, vsync: tester, initialIndex: 1);
      addTearDown(old.dispose);
      addTearDown(next.dispose);
      await tester.pumpWidget(_host(_tabs(old)));
      await tester.pumpWidget(_host(_tabs(next)));
      await tester.pumpAndSettle();
      expect(find.text('Body 1'), findsOneWidget);
      expect(old.listenerCount, 0);
      expect(old.observed.listenerCount, 0);
      old.animateTo(1);
      await tester.pumpAndSettle();
      expect(find.text('Body 1'), findsOneWidget);
      next.animateTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Body 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(next.listenerCount, 0);
      expect(next.observed.listenerCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same tab widgets support growing, empty and shrinking controller lengths',
    (tester) async {
      final controllers = [
        for (final length in [2, 3, 0, 1])
          _TrackedTabs(length: length, vsync: tester),
      ];
      addTearDown(() {
        for (final controller in controllers) {
          controller.dispose();
        }
      });
      State? first;
      for (final controller in controllers) {
        await tester.pumpWidget(_host(_tabs(controller)));
        await tester.pumpAndSettle();
        first ??= tester.state(find.byType(AppTabBar));
        expect(tester.state(find.byType(AppTabBar)), same(first));
        expect(tester.takeException(), isNull);
        expect(find.byType(Tab), findsNWidgets(controller.length));
        if (controller.length > 0) {
          controller.index = controller.length - 1;
          await tester.pumpAndSettle();
          expect(find.text('Body ${controller.length - 1}'), findsOneWidget);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      for (final controller in controllers) {
        expect(controller.observed.listenerCount, 0);
        expect(controller.listenerCount, 0);
      }
    },
  );

  for (final sliver in [false, true]) {
    testWidgets(
      'search controller replacement and removal own text resources (sliver=$sliver)',
      (tester) async {
        final oldQueries = <String>[];
        final newQueries = <String>[];
        final old = SearchBarController(
          currentText: 'old seed',
          onSearch: oldQueries.add,
        );
        final next = SearchBarController(
          currentText: 'new seed',
          onSearch: newQueries.add,
        );
        await tester.pumpWidget(_host(_search(old, sliver)));
        final editing = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        await tester.enterText(find.byType(TextField), 'old draft');
        await tester.pumpWidget(_host(_search(next, sliver)));
        await tester.pumpAndSettle();
        expect(next.text, 'new seed');
        expect(old.text, '');
        old.setText('retired edit');
        expect(next.text, 'new seed');
        next.setText('new query');
        await tester.pump();
        tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
          'new query',
        );
        expect(oldQueries, isEmpty);
        expect(newQueries, ['new query']);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(next.text, '');
        next.setText('detached edit');
        expect(() => editing.addListener(() {}), throwsFlutterError);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'removing an older search owner preserves the latest binding (sliver=$sliver)',
      (tester) async {
        final controller = SearchBarController(currentText: 'seed');
        Widget owners(bool showOld) => _host(
          Column(
            children: [
              if (showOld)
                Expanded(
                  child: _search(
                    controller,
                    sliver,
                    key: const ValueKey('old'),
                  ),
                ),
              Expanded(
                child: _search(
                  controller,
                  sliver,
                  key: const ValueKey('latest'),
                ),
              ),
            ],
          ),
        );
        await tester.pumpWidget(owners(true));
        await tester.pumpWidget(owners(false));
        controller.text = 'latest query';
        await tester.pump();
        expect(find.text('latest query'), findsOneWidget);
        expect(controller.text, 'latest query');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(controller.text, '');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('sliver search updates live change callback, focus and action', (
    tester,
  ) async {
    final controller = SearchBarController();
    final firstFocus = FocusNode();
    final nextFocus = FocusNode();
    final firstChanges = <String>[];
    final nextChanges = <String>[];
    addTearDown(firstFocus.dispose);
    addTearDown(nextFocus.dispose);
    Widget show(bool next) => _host(
      CustomScrollView(
        slivers: [
          SliverSearchBar(
            controller: controller,
            focusNode: next ? nextFocus : firstFocus,
            onChanged: next ? nextChanges.add : firstChanges.add,
            action: Text(next ? 'New action' : 'Old action'),
          ),
        ],
      ),
    );
    await tester.pumpWidget(show(false));
    await tester.pumpWidget(show(true));
    await tester.enterText(find.byType(TextField), 'query');
    expect(firstChanges, isEmpty);
    expect(nextChanges, ['query']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode,
      same(nextFocus),
    );
    expect(find.text('New action'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    nextFocus.addListener(() {});
    expect(tester.takeException(), isNull);
  });
}
