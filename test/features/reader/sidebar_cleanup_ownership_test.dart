import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/side_bar.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/reader/sidebar_binding.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork, sidebarCauses;

class _Owner extends StatefulWidget {
  const _Owner({required this.binding, required this.onContext});
  final ReaderSidebarBinding binding;
  final ValueChanged<BuildContext> onContext;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  void dispose() {
    widget.binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.onContext(context);
    return const Text('Reader owner');
  }
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final visible = ValueNotifier(true);
  final registries = <SelectionTaskRegistry>[];
  final events = <String>[];
  final errors = <({Object error, StackTrace stack})>[];
  SelectionTaskRegistry registry = SelectionTaskRegistry();
  late BuildContext context;
  bool window = false;
  int exits = 0;
  VoidCallback? duringAcquire;
  VoidCallback? duringRelease;
  late final binding = ReaderSidebarBinding(
    canOpen: () => true,
    acquireInteraction: () {
      events.add('pause');
      duringAcquire?.call();
      return () {
        events.add('release');
        duringRelease?.call();
      };
    },
    onError: (error, stack) => errors.add((error: error, stack: stack)),
  );
  _NavigatorState get navigation => navigator.currentState! as _NavigatorState;

  Widget tree() => MaterialApp(
    builder: (_, _) {
      Widget child = _Navigator(
        key: navigator,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? _Owner(
                      binding: binding,
                      onContext: (value) => context = value,
                    )
                  : const Text('Reader removed'),
            ),
          ),
        ),
      );
      if (window) child = WindowFrame(child, onExit: () => exits++);
      return SelectionTasksScope(registry: registry, child: child);
    },
  );

  Future<void> mount(WidgetTester tester) async {
    registries.add(registry);
    await tester.pumpWidget(tree());
    addTearDown(() async {
      navigator.currentState?.letClearFailures();
      binding.dispose();
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      for (final original in registries) {
        await settleSidebarWork(tester, original.closeAndWait);
      }
      visible.dispose();
    });
  }

  ReaderSidebarHandle? show([String text = 'Original sidebar']) =>
      binding.show(context, Text(text));

  SideBarRoute<void> route(
    WidgetTester tester, [
    String text = 'Original sidebar',
  ]) => ModalRoute.of(tester.element(find.text(text)))! as SideBarRoute<void>;
}

extension on NavigatorState {
  void letClearFailures() => (this as _NavigatorState).failures.clear();
}

class _Navigator extends Navigator {
  const _Navigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _NavigatorState();
}

class _NavigatorState extends NavigatorState {
  final failures = <Route<dynamic>>{};
  final removed = <Route<dynamic>>[];
  final failure = StateError('original reader sidebar removal failed');
  final failureStack = StackTrace.fromString('original sidebar removal stack');
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removed.add(route);
    if (failures.contains(route)) {
      Error.throwWithStackTrace(failure, failureStack);
    }
    super.removeRoute(route, result);
  }
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

  for (final trigger in ['handle', 'binding', 'dispose']) {
    testWidgets('failed reader removal is explicitly retryable: $trigger', (
      tester,
    ) async {
      final host = _Host();
      await host.mount(tester);
      final handle = host.show()!;
      await tester.pumpAndSettle();
      final original = host.route(tester);
      host.navigation.failures.add(original);
      final newer = MaterialPageRoute<void>(
        builder: (_) => const Text('Newer page'),
      );
      host.navigation.push(newer);
      await pumpSidebar(tester);
      void close() {
        if (trigger == 'handle') {
          handle.close();
        } else if (trigger == 'binding') {
          host.binding.close();
        } else {
          host.binding.dispose();
        }
      }

      close();
      close();
      await pumpSidebar(tester);
      expect(host.navigation.removed, [original]);
      expect(original.isActive, isTrue);
      expect(newer.isCurrent, isTrue);
      expect(handle.isCurrent, isFalse);
      expect(host.events, ['pause', 'release']);
      expect(host.errors.single.error, same(host.navigation.failure));
      expect(host.errors.single.stack, same(host.navigation.failureStack));
      host.navigation.failures.clear();
      close();
      await pumpSidebar(tester);
      expect(host.navigation.removed, [original, original]);
      expect(original.isActive, isFalse);
      expect(newer.isCurrent, isTrue);
      expect(host.events, ['pause', 'release']);
      expect(host.errors, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('application closure retains a failed original reader route', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final handle = host.show()!;
    await tester.pumpAndSettle();
    final original = host.route(tester);
    host.navigation.failures.add(original);
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Text('Newer page'),
    );
    host.navigation.push(newer);
    await pumpSidebar(tester);
    Object? error;
    await settleSidebarWork(
      tester,
      () => host.registry.closeAndWait().catchError((Object value) {
        error = value;
      }),
    );
    expect(error, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(error!), contains(same(host.navigation.failure)));
    expect(host.navigation.removed, [original]);
    expect(original.isActive, isTrue);
    expect(handle.isCurrent, isFalse);
    expect(host.events, ['pause', 'release']);
    host.navigation.failures.clear();
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(host.navigation.removed, [original, original]);
    expect(original.isActive, isFalse);
    expect(newer.isCurrent, isTrue);
    expect(host.events, ['pause', 'release']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removed reader leaves failed cleanup with its original host', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    host.show();
    await tester.pumpAndSettle();
    final original = host.route(tester);
    host.navigation.failures.add(original);
    host.visible.value = false;
    await pumpSidebar(tester);
    expect(host.context.mounted, isFalse);
    expect(host.navigation.removed, [original]);
    Object? error;
    await settleSidebarWork(
      tester,
      () => host.registry.closeAndWait().catchError((Object value) {
        error = value;
      }),
    );
    expect(error, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(error!), contains(same(host.navigation.failure)));
    expect(host.navigation.removed, [original, original]);
    expect(host.events, ['pause', 'release']);
    host.navigation.failures.clear();
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(host.navigation.removed, [original, original, original]);
    expect(original.isActive, isFalse);
    expect(host.events, ['pause', 'release']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement application cannot adopt an old reader sidebar', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final handle = host.show()!;
    await tester.pumpAndSettle();
    final original = host.route(tester);
    final registry = host.registry;
    host.registry = SelectionTaskRegistry();
    host.registries.add(host.registry);
    await tester.pumpWidget(host.tree());
    await pumpSidebar(tester);
    expect(handle.isCurrent, isFalse);
    await settleSidebarWork(tester, host.registry.closeAndWait);
    expect(original.isActive, isTrue);
    expect(host.navigation.removed, isEmpty);
    await settleSidebarWork(tester, registry.closeAndWait);
    expect(original.isActive, isFalse);
    expect(host.navigation.removed, [original]);
    expect(host.events, ['pause', 'release']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('window exit waits for failed reader removal and retries it', (
    tester,
  ) async {
    final host = _Host()..window = true;
    await host.mount(tester);
    host.show();
    await tester.pumpAndSettle();
    final original = host.route(tester);
    host.navigation.failures.add(original);
    final window = tester.state(find.byType(WindowFrame)) as WindowListener;
    window.onWindowClose();
    await pumpSidebar(tester);
    final failure = tester.takeException();
    expect(failure, isA<SelectionCleanupFailure>());
    expect(sidebarCauses(failure!), contains(same(host.navigation.failure)));
    expect(host.exits, 0);
    expect(host.navigation.removed, [original]);
    expect(original.isActive, isTrue);
    expect(host.events, ['pause', 'release']);
    host.navigation.failures.clear();
    window.onWindowClose();
    await pumpSidebar(tester);
    expect(host.exits, 1);
    expect(host.navigation.removed, [original, original]);
    expect(original.isActive, isFalse);
    expect(host.events, ['pause', 'release']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader lifetime is registered before reentrant pause acquisition',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      Future<void>? closing;
      host.duringAcquire = () {
        closing = host.registry.closeAndWait().then(
          (_) => host.events.add('closed'),
        );
      };
      host.show();
      await pumpSidebar(tester);
      await settleSidebarWork(tester, () => closing!);
      expect(find.text('Original sidebar'), findsNothing);
      expect(host.events, ['pause', 'release', 'closed']);
      expect(host.errors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closed application rejects a new reader pause and presentation',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(host.show(), isNull);
      await pumpSidebar(tester);
      expect(host.events, isEmpty);
      expect(find.text('Original sidebar'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'borrowed release failure is reported once without replay on close',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final releaseError = StateError('borrowed release failed');
      host.duringRelease = () => throw releaseError;
      host.show();
      await tester.pumpAndSettle();
      final original = host.route(tester);
      await settleSidebarWork(tester, host.registry.closeAndWait);
      expect(original.isActive, isFalse);
      expect(host.events, ['pause', 'release']);
      expect(host.errors.single.error, same(releaseError));
      await settleSidebarWork(tester, host.registry.closeAndWait);
      host.binding.dispose();
      await pumpSidebar(tester);
      expect(host.events, ['pause', 'release']);
      expect(host.errors, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
