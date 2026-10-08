import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/input_dialog.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:window_manager/window_manager.dart';

import 'js_ui_ownership_test.dart' show drainUi;

class _Host {
  _Host({this.window = false});
  final bool window;
  final tasks = SelectionTaskRegistry();
  final navigator = GlobalKey<NavigatorState>();
  late BuildContext context;
  bool allowed = true;
  int exits = 0;

  Widget app({SelectionTaskRegistry? registry}) => MaterialApp(
    navigatorKey: navigator,
    builder: (_, child) => NavigationAdmission(
      allowsNavigation: () => allowed,
      child: SelectionTasksScope(
        registry: registry ?? tasks,
        child: window ? WindowFrame(child!, onExit: () => exits++) : child!,
      ),
    ),
    home: Builder(
      builder: (value) {
        context = value;
        return const Scaffold(body: Text('Original application'));
      },
    ),
  );
}

void main() {
  setUp(() {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
  });

  Future<_Host> host(WidgetTester tester, {bool window = false}) async {
    final owner = _Host(window: window);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await drainUi(tester, owner.tasks.closeAndWait);
    });
    await tester.pumpWidget(owner.app());
    return owner;
  }

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> open(
    WidgetTester tester,
    _Host owner,
    FutureOr<Object?> Function(String) confirm,
  ) async {
    unawaited(
      showInputDialog(
        context: owner.context,
        title: 'Original input',
        initialValue: 'Original value',
        onConfirm: confirm,
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback confirm(WidgetTester tester) =>
      tester.widget<Button>(find.byType(Button)).onPressed;

  MaterialPageRoute<void> cover(_Host owner) {
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('New page')),
    );
    unawaited(owner.navigator.currentState!.push(route));
    return route;
  }

  testWidgets('input rejects synchronous confirmation reentry', (tester) async {
    final owner = await host(tester);
    final pending = Completer<Object?>();
    var calls = 0;
    late VoidCallback press;
    await open(tester, owner, (_) {
      calls++;
      if (calls == 1) press();
      return pending.future;
    });
    press = confirm(tester);
    try {
      press();
      await tester.pump();
      expect(calls, 1);
    } finally {
      pending.complete(null);
      await frames(tester);
    }
  });

  for (final covered in [false, true]) {
    testWidgets('input rejects inactive confirmation; covered=$covered', (
      tester,
    ) async {
      final owner = await host(tester);
      var calls = 0;
      await open(tester, owner, (_) {
        calls++;
        return null;
      });
      final press = confirm(tester);
      if (covered) {
        cover(owner);
        await frames(tester);
      } else {
        owner.allowed = false;
      }
      press();
      await frames(tester);
      expect(calls, 0);
    });
  }

  testWidgets('covered committed input only closes its own route on return', (
    tester,
  ) async {
    final owner = await host(tester);
    final pending = Completer<Object?>();
    var calls = 0;
    await open(tester, owner, (_) {
      calls++;
      return pending.future;
    });
    confirm(tester)();
    await tester.pump();
    final newer = cover(owner);
    await frames(tester);
    pending.complete(null);
    await frames(tester);
    expect(newer.isCurrent, isTrue);
    expect(calls, 1);
    owner.navigator.currentState!.pop();
    await frames(tester);
    confirm(tester)();
    await frames(tester);
    expect(calls, 1);
    expect(find.text('Original input'), findsNothing);
  });

  testWidgets('frozen input retains a completed confirmation without replay', (
    tester,
  ) async {
    final owner = await host(tester);
    final pending = Completer<Object?>();
    var calls = 0;
    await open(tester, owner, (_) {
      calls++;
      return pending.future;
    });
    confirm(tester)();
    await tester.pump();
    owner.allowed = false;
    pending.complete(null);
    await frames(tester);
    expect(find.text('Original input'), findsOneWidget);
    owner.allowed = true;
    confirm(tester)();
    await frames(tester);
    expect(calls, 1);
    expect(find.text('Original input'), findsNothing);
  });

  for (final state in PersistenceCommitState.values) {
    testWidgets('input observes persistence commit state; state=$state', (
      tester,
    ) async {
      final owner = await host(tester);
      var calls = 0;
      await open(tester, owner, (_) async {
        calls++;
        if (calls == 1) {
          throw PersistenceFailure(
            commitState: state,
            cause: StateError('original write error'),
            stackTrace: StackTrace.current,
          );
        }
        return null;
      });
      confirm(tester)();
      await tester.pumpAndSettle();
      expect(find.textContaining('original write error'), findsOneWidget);
      confirm(tester)();
      await tester.pumpAndSettle();
      expect(calls, state == PersistenceCommitState.notCommitted ? 2 : 1);
      expect(find.text('Original input'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('input confirmation stays registered with its original host', (
    tester,
  ) async {
    final owner = await host(tester);
    final replacement = SelectionTaskRegistry();
    final pending = Completer<Object?>();
    await open(tester, owner, (_) => pending.future);
    confirm(tester)();
    await tester.pump();
    await tester.pumpWidget(owner.app(registry: replacement));
    var oldClosed = false;
    var newClosed = false;
    final oldClosing = owner.tasks.closeAndWait().then<void>(
      (_) => oldClosed = true,
    );
    final newClosing = replacement.closeAndWait().then<void>(
      (_) => newClosed = true,
    );
    try {
      await frames(tester);
      expect(oldClosed, isFalse);
      expect(newClosed, isTrue);
    } finally {
      pending.complete(null);
      await drainUi(tester, () async {
        await Future.wait([oldClosing, newClosing]);
      });
    }
    expect(find.text('Original input'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'input registers before synchronous shutdown inside confirmation',
    (tester) async {
      final owner = await host(tester);
      final pending = Completer<Object?>();
      var closed = false;
      Future<void>? closing;
      await open(tester, owner, (_) {
        closing = owner.tasks.closeAndWait().then<void>((_) => closed = true);
        return pending.future;
      });
      confirm(tester)();
      try {
        await frames(tester);
        expect(closing, isNotNull);
        expect(closed, isFalse);
      } finally {
        pending.complete(null);
        await drainUi(tester, () => closing!);
      }
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final window in [false, true]) {
    testWidgets('original host joins dismissed input work; window=$window', (
      tester,
    ) async {
      final owner = await host(tester, window: window);
      final pending = Completer<Object?>();
      await open(tester, owner, (_) => pending.future);
      confirm(tester)();
      await tester.pump();
      owner.navigator.currentState!.pop();
      await frames(tester);
      var closed = false;
      Future<void>? closing;
      if (window) {
        (tester.state(find.byType(WindowFrame)) as WindowListener)
            .onWindowClose();
      } else {
        await tester.pumpWidget(const SizedBox());
        closing = owner.tasks.closeAndWait().then<void>((_) => closed = true);
      }
      try {
        await frames(tester);
        expect(window ? owner.exits != 0 : closed, isFalse);
      } finally {
        pending.completeError(StateError('late original write failure'));
        await frames(tester);
        if (closing != null) await drainUi(tester, () => closing!);
      }
      expect(window ? owner.exits : (closed ? 1 : 0), 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('input completes and releases before its first route build', (
    tester,
  ) async {
    final owner = await host(tester);
    var closures = 0;
    var completed = false;
    final shown = showInputDialog(
      context: owner.context,
      title: 'Never built input',
      onConfirm: (_) => null,
      onClosed: () => closures++,
    ).then<void>((_) => completed = true);
    await tester.idle();
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(completed, isTrue);
    expect(closures, 1);
    await shown;
  });

  testWidgets(
    'ordinary input failure remains with its caller during host close',
    (tester) async {
      final owner = await host(tester);
      final pending = Completer<Object?>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
      });
      var calls = 0;
      await open(tester, owner, (_) {
        calls++;
        return pending.future;
      });
      confirm(tester)();
      await frames(tester);
      Object? closeFailure;
      var finished = false;
      final closing = owner.tasks.closeAndWait().then<void>(
        (_) => finished = true,
        onError: (Object error) => closeFailure = error,
      );
      await frames(tester);
      expect(finished, isFalse);
      pending.completeError(StateError('ordinary input confirmation'));
      await drainUi(tester, () => closing);
      await frames(tester);
      expect(closeFailure, isNull);
      expect(finished, isTrue);
      expect(calls, 1);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('input disposal releases its controller and callback once', (
    tester,
  ) async {
    final owner = await host(tester);
    var closures = 0;
    final shown = showInputDialog(
      context: owner.context,
      title: 'Owned input',
      onConfirm: (_) => null,
      onClosed: () => closures++,
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    await shown;
    expect(closures, 1);
    expect(() => controller.addListener(() {}), throwsFlutterError);
  });

  testWidgets('covered content close does not dismiss a newer page', (
    tester,
  ) async {
    final owner = await host(tester);
    await open(tester, owner, (_) => null);
    final close = tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
        .onPressed!;
    final newer = cover(owner);
    await frames(tester);
    close();
    await frames(tester);
    expect(newer.isCurrent, isTrue);
  });

  testWidgets('busy input retains its accessible confirmation name', (
    tester,
  ) async {
    final owner = await host(tester);
    final semantics = tester.ensureSemantics();
    final pending = Completer<Object?>();
    try {
      await open(tester, owner, (_) => pending.future);
      confirm(tester)();
      await tester.pump();
      expect(find.bySemanticsLabel('Confirm'), findsOneWidget);
    } finally {
      pending.complete(null);
      await frames(tester);
      semantics.dispose();
    }
  });

  testWidgets(
    'failed input route removal ends its waiter and remains retryable',
    (tester) async {
      final owner = await host(tester);
      await tester.pumpWidget(const SizedBox());
      final navigator = GlobalKey<_FailingNavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, _) => SelectionTasksScope(
            registry: owner.tasks,
            child: _FailingNavigator(
              key: navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (value) {
                  owner.context = value;
                  return const Scaffold();
                },
              ),
            ),
          ),
        ),
      );
      var closures = 0;
      Object? presentationError;
      final shown =
          showInputDialog(
            context: owner.context,
            title: 'Retry original close',
            onConfirm: (_) => null,
            onClosed: () => closures++,
          ).catchError((Object error) {
            presentationError = error;
          });
      await tester.pumpAndSettle();
      Object? closeError;
      final firstClose = owner.tasks.closeAndWait().catchError((Object error) {
        closeError = error;
      });
      await drainUi(tester, () => firstClose);
      await shown;
      expect(closeError, isA<SelectionCleanupFailure>());
      expect(presentationError, isA<SelectionCleanupFailure>());
      expect(closures, 0);
      expect(find.text('Retry original close'), findsOneWidget);
      navigator.currentState!.fails = false;
      await drainUi(tester, owner.tasks.closeAndWait);
      await frames(tester);
      expect(closures, 1);
      expect(find.text('Retry original close'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailingNavigator extends Navigator {
  const _FailingNavigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _FailingNavigatorState();
}

class _FailingNavigatorState extends NavigatorState {
  bool fails = true;
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    if (fails) throw StateError('original route removal failed');
    super.removeRoute(route, result);
  }
}
