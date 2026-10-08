import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

Future<void> pumpSidebar(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> settleSidebarWork(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final result = action().then<void>(
    (_) => done = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expectSync(done, isTrue, reason: 'The original sidebar work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

Iterable<Object> sidebarCauses(Object error) sync* {
  yield error;
  if (error is SelectionCleanupFailure) {
    if (error.operationError != null) {
      yield* sidebarCauses(error.operationError!);
    }
    for (final failure in error.failures) {
      if (failure case (error: final Object cause, stack: final StackTrace _)) {
        yield* sidebarCauses(cause);
      } else {
        yield* sidebarCauses(failure);
      }
    }
  }
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final registries = <SelectionTaskRegistry>[];
  SelectionTaskRegistry registry = SelectionTaskRegistry();
  late BuildContext context;
  bool allowed = true;
  bool failing = false;
  bool window = false;
  int exits = 0;

  Widget tree() => MaterialApp(
    builder: (_, _) {
      Widget child = failing
          ? _FailingNavigator(key: navigator, onGenerateRoute: _home)
          : Navigator(key: navigator, onGenerateRoute: _home);
      if (window) child = WindowFrame(child, onExit: () => exits++);
      return SelectionTasksScope(
        registry: registry,
        child: NavigationAdmission(
          allowsNavigation: () => allowed,
          child: child,
        ),
      );
    },
  );

  Route<void> _home(RouteSettings settings) => MaterialPageRoute<void>(
    builder: (value) {
      context = value;
      return const Scaffold(body: Text('Original page'));
    },
  );

  Future<void> mount(WidgetTester tester) async {
    registries.add(registry);
    await tester.pumpWidget(tree());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      for (final original in registries) {
        await settleSidebarWork(tester, original.closeAndWait);
      }
    });
  }

  Future<void> show({bool showBarrier = true, bool dismissible = true}) =>
      showSideBar(
        context,
        const Scaffold(body: Text('Owned sidebar')),
        showBarrier: showBarrier,
        dismissible: dismissible,
      );

  SideBarRoute<dynamic> route(WidgetTester tester) =>
      ModalRoute.of(tester.element(find.text('Owned sidebar')))!
          as SideBarRoute<dynamic>;
}

void main() {
  const channel = MethodChannel('window_manager');
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() {
      Log.isMuted = muted;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  for (final built in [false, true]) {
    testWidgets('sidebar wait ends with Navigator disposal: built=$built', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      var finished = false;
      host.show().then((_) => finished = true).ignore();
      if (built) {
        await pumpSidebar(tester);
      } else {
        await tester.idle();
      }
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      expect(finished, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('original application closes only its sidebar under a new page', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    var finished = false;
    host.show().then((_) => finished = true).ignore();
    await pumpSidebar(tester);
    final route = host.route(tester);
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Newer page')),
    );
    host.navigator.currentState!.push(newer);
    await pumpSidebar(tester);
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(finished, isTrue);
    expect(route.isActive, isFalse);
    expect(newer.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window exit releases the sidebar presentation before exiting', (
    tester,
  ) async {
    final host = _Host()..window = true;
    await host.mount(tester);
    var finished = false;
    host.show().then((_) => finished = true).ignore();
    await pumpSidebar(tester);
    final route = host.route(tester);
    (tester.state(find.byType(WindowFrame)) as WindowListener).onWindowClose();
    await pumpSidebar(tester);
    expect(finished, isTrue);
    expect(route.isActive, isFalse);
    expect(host.exits, 1);
    expect(tester.takeException(), isNull);
  });

  for (final state in ['frozen', 'covered', 'closed']) {
    testWidgets('inactive caller cannot present a sidebar: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      if (state == 'frozen') {
        host.allowed = false;
      } else if (state == 'closed') {
        await settleSidebarWork(tester, host.registry.closeAndWait);
      } else {
        host.navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const Text('Newer page')),
        );
        await pumpSidebar(tester);
      }
      host.show().ignore();
      await pumpSidebar(tester);
      expect(find.text('Owned sidebar'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final state in ['covered', 'frozen', 'replacement']) {
    testWidgets('retained barrier cannot dismiss another owner: $state', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      host.show().ignore();
      await pumpSidebar(tester);
      final route = host.route(tester);
      final listener = route.buildModalBarrier() as Listener;
      final barrier = listener.child! as ModalBarrier;
      listener.onPointerDown!(const PointerDownEvent(position: Offset(1, 1)));
      Route<void>? newer;
      if (state == 'covered') {
        newer = MaterialPageRoute<void>(
          builder: (_) => const Text('Newer page'),
        );
        host.navigator.currentState!.push(newer);
        await pumpSidebar(tester);
      } else if (state == 'frozen') {
        host.allowed = false;
      } else {
        host.registry = SelectionTaskRegistry();
        host.registries.add(host.registry);
        await tester.pumpWidget(host.tree());
        await pumpSidebar(tester);
      }
      barrier.onDismiss!();
      await pumpSidebar(tester);
      expect(route.isActive, isTrue);
      expect(newer?.isCurrent ?? route.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('barrier still requires a nonzero pointer before dismissal', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final result = host.show();
    await pumpSidebar(tester);
    final route = host.route(tester);
    final listener = route.buildModalBarrier() as Listener;
    final barrier = listener.child! as ModalBarrier;
    barrier.onDismiss!();
    await pumpSidebar(tester);
    expect(route.isCurrent, isTrue);
    listener.onPointerDown!(const PointerDownEvent());
    barrier.onDismiss!();
    await pumpSidebar(tester);
    expect(route.isCurrent, isTrue);
    listener.onPointerDown!(const PointerDownEvent(position: Offset(1, 1)));
    barrier.onDismiss!();
    await settleSidebarWork(tester, () => result);
    expect(route.isActive, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden and non-dismissible barriers retain their old policy', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    host.show(showBarrier: false).ignore();
    await pumpSidebar(tester);
    expect(host.route(tester).buildModalBarrier(), isA<SizedBox>());
    host.navigator.currentState!.pop();
    await pumpSidebar(tester);
    host.show(dismissible: false).ignore();
    await pumpSidebar(tester);
    final listener = host.route(tester).buildModalBarrier() as Listener;
    expect((listener.child! as ModalBarrier).onDismiss, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed removal ends waiting and retains its route for retry', (
    tester,
  ) async {
    final host = _Host()..failing = true;
    await host.mount(tester);
    final navigator = host.navigator.currentState! as _FailingNavigatorState;
    Object? presentationError;
    final result = host.show().then<void>(
      (_) {},
      onError: (Object error) {
        presentationError = error;
      },
    );
    await pumpSidebar(tester);
    final route = host.route(tester);
    try {
      Object? closeError;
      await settleSidebarWork(
        tester,
        () => host.registry.closeAndWait().catchError((Object error) {
          closeError = error;
        }),
      );
      expect(closeError, isA<SelectionCleanupFailure>());
      await settleSidebarWork(tester, () => result);
      expect(sidebarCauses(closeError!), contains(same(navigator.failure)));
      expect(
        sidebarCauses(presentationError!),
        contains(same(navigator.failure)),
      );
      expect(navigator.removals, 1);
      expect(route.isActive, isTrue);
      navigator.fails = false;
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(navigator.removals, 2);
      expect(route.isActive, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      navigator.fails = false;
    }
  });
  testWidgets(
    'presentation errors are observed when callers only open a sidebar',
    (tester) async {
      final host = _Host()..failing = true;
      await host.mount(tester);
      final navigator = host.navigator.currentState! as _FailingNavigatorState;
      unawaited(host.show());
      await pumpSidebar(tester);
      try {
        Object? closeError;
        await settleSidebarWork(
          tester,
          () => host.registry.closeAndWait().catchError((Object error) {
            closeError = error;
          }),
        );
        expect(closeError, isA<SelectionCleanupFailure>());
        expect(sidebarCauses(closeError!), contains(same(navigator.failure)));
        expect(tester.takeException(), isNull);
        navigator.fails = false;
        await settleSidebarWork(tester, host.registry.closeAndWait);
        expect(navigator.removals, 2);
      } finally {
        navigator.fails = false;
      }
    },
  );

  testWidgets('typed sidebar results return through the nearest Navigator', (
    tester,
  ) async {
    final root = GlobalKey<NavigatorState>();
    final nested = GlobalKey<NavigatorState>();
    final registry = SelectionTaskRegistry();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: root,
        builder: (_, child) =>
            SelectionTasksScope(registry: registry, child: child!),
        home: Navigator(
          key: nested,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await settleSidebarWork(tester, registry.closeAndWait);
    });
    final result = showSideBar<String>(
      context,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).pop('selected chapter'),
          child: const Text('Select chapter'),
        ),
      ),
    );
    await pumpSidebar(tester);
    expect(root.currentState!.canPop(), isFalse);
    expect(nested.currentState!.canPop(), isTrue);
    await tester.tap(find.text('Select chapter'));
    String? selected;
    await settleSidebarWork(tester, () async {
      selected = await result;
    });
    expect(selected, 'selected chapter');
    expect(nested.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}

class _FailingNavigator extends Navigator {
  const _FailingNavigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _FailingNavigatorState();
}

class _FailingNavigatorState extends NavigatorState {
  bool fails = true;
  int removals = 0;
  final failure = StateError('sidebar route removal failed');
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removals++;
    if (fails) throw failure;
    super.removeRoute(route, result);
  }
}
