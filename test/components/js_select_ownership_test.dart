import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import 'js_ui_ownership_test.dart' show drainUi;

void main() {
  late JsEngine engine;
  late JsUiApi api;
  late SelectionTaskRegistry tasks;
  bool allowed = true;
  final registries = <SelectionTaskRegistry>[];

  setUp(() {
    rootBundle.clear();
    engine = JsEngine.create();
    api = JsUiApi();
    registries.clear();
    allowed = true;
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    Log.isMuted = true;
    appdata.settings['language'] = 'en-US';
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
  });

  Future<void> mount(WidgetTester tester) async {
    tasks = SelectionTaskRegistry();
    registries.add(tasks);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        builder: (_, child) => NavigationAdmission(
          allowsNavigation: () => allowed,
          child: SelectionTasksScope(registry: tasks, child: child!),
        ),
        home: const Scaffold(body: Text('Home')),
      ),
    );
  }

  Future<void> host(WidgetTester tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      for (final registry in registries) {
        await drainUi(tester, registry.closeAndWait);
      }
      await drainUi(tester, engine.closeAndWait);
    });
    await mount(tester);
  }

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<int?> choose({int? initial = 1, List<Object>? options}) =>
      api.handleUIMessage({
            'function': 'showSelectDialog',
            'title': 'Original choice',
            'options': options ?? ['First', 'Second'],
            'initialIndex': initial,
          }, engine: engine)
          as Future<int?>;

  testWidgets('empty filtered selection does not require a UI host', (
    tester,
  ) async {
    addTearDown(engine.closeAndWait);
    expect(await choose(options: [42]), isNull);
    expect(tester.takeException(), isNull);
  });

  for (final action in [
    'confirm',
    'cancel',
    'back',
    'barrier',
    'change-back',
  ]) {
    testWidgets('selection preserves existing dismissal result: $action', (
      tester,
    ) async {
      await host(tester);
      final result = choose();
      await tester.pumpAndSettle();
      if (action == 'change-back') {
        await tester.tap(find.byType(Select));
        await tester.pumpAndSettle();
        await tester.tap(find.text('First'));
        await tester.pumpAndSettle();
      }
      switch (action) {
        case 'confirm':
          await tester.tap(find.text('Confirm'));
        case 'cancel':
          await tester.tap(find.text('Cancel'));
        case 'barrier':
          await tester.tapAt(const Offset(1, 1));
        default:
          appNavigation.rootNavigatorKey.currentState!.pop();
      }
      await frames(tester);
      expect(
        await result,
        action == 'cancel' ? null : (action == 'change-back' ? 0 : 1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('selection filters strings and preserves filtered indices', (
    tester,
  ) async {
    await host(tester);
    final result = choose(options: ['First', 42, 'Second']);
    await tester.pumpAndSettle();
    expect(tester.widget<Select>(find.byType(Select)).current, 'Second');
    await tester.tap(find.text('Confirm'));
    await frames(tester);
    expect(await result, 1);
    final invalid = choose(initial: 99);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await frames(tester);
    expect(await invalid, isNull);
  });

  for (final covered in [false, true]) {
    testWidgets(
      'selection rejects old callbacks after admission closes; covered=$covered',
      (tester) async {
        await host(tester);
        unawaited(choose());
        await tester.pumpAndSettle();
        final select = tester.widget<Select>(find.byType(Select)).onTap!;
        final confirm = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed!;
        MaterialPageRoute<void>? newer;
        if (covered) {
          newer = MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('New page')),
          );
          unawaited(appNavigation.rootNavigatorKey.currentState!.push(newer));
          await frames(tester);
        } else {
          allowed = false;
        }
        select(0);
        confirm();
        await frames(tester);
        if (covered) {
          expect(newer!.isCurrent, isTrue);
        } else {
          expect(tester.widget<Select>(find.byType(Select)).current, 'Second');
        }
      },
    );
  }

  for (final built in [false, true]) {
    testWidgets(
      'Navigator disposal completes selection cancellation; built=$built',
      (tester) async {
        await host(tester);
        var completed = false;
        int? selected;
        final result = choose().then<void>((value) {
          completed = true;
          selected = value;
        });
        await tester.idle();
        if (built) await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
        expect(completed, isTrue);
        expect(selected, isNull);
        await result;
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('old JS selection handler cannot adopt a replacement Navigator', (
    tester,
  ) async {
    await host(tester);
    final first = choose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await frames(tester);
    await first;
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    Object? caught;
    try {
      choose();
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<JsDisposedError>());
  });

  testWidgets('application close removes only its covered choice route', (
    tester,
  ) async {
    await host(tester);
    var completed = false;
    int? selected;
    final result = choose().then<void>((value) {
      completed = true;
      selected = value;
    });
    await tester.pumpAndSettle();
    final newer = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('New page')),
    );
    unawaited(appNavigation.rootNavigatorKey.currentState!.push(newer));
    await frames(tester);
    await drainUi(tester, tasks.closeAndWait);
    await frames(tester);
    expect(newer.isCurrent, isTrue);
    expect(completed, isTrue);
    expect(selected, isNull);
    await result;
    expect(find.text('Original choice', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposed selection callbacks cannot update or close a later route',
    (tester) async {
      await host(tester);
      final shown = choose();
      await tester.pumpAndSettle();
      final select = tester.widget<Select>(find.byType(Select)).onTap!;
      final confirm = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      final cancel = tester
          .widget<TextButton>(find.byType(TextButton))
          .onPressed!;
      cancel();
      await frames(tester);
      expect(await shown, isNull);
      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Later page')),
      );
      unawaited(appNavigation.rootNavigatorKey.currentState!.push(newer));
      await frames(tester);
      select(0);
      confirm();
      cancel();
      await frames(tester);
      expect(newer.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed selection removal ends its waiter and retains the original route',
    (tester) async {
      await host(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, _) => SelectionTasksScope(
            registry: tasks,
            child: _FailingNavigator(
              key: appNavigation.rootNavigatorKey,
              onGenerateRoute: (_) =>
                  MaterialPageRoute<void>(builder: (_) => const Scaffold()),
            ),
          ),
        ),
      );
      final navigator =
          appNavigation.rootNavigatorKey.currentState!
              as _FailingNavigatorState;
      Object? presentationError;
      var presentationEnded = false;
      final shown = choose().then<void>(
        (_) => presentationEnded = true,
        onError: (Object error) {
          presentationError = error;
          presentationEnded = true;
        },
      );
      await tester.pumpAndSettle();
      Object? closeError;
      final closing = tasks.closeAndWait().catchError((Object error) {
        closeError = error;
      });
      try {
        await drainUi(tester, () => closing);
        expect(presentationEnded, isTrue);
        await shown;
        expect(closeError, isA<SelectionCleanupFailure>());
        expect(presentationError, isA<SelectionCleanupFailure>());
        expect(navigator.removals, 1);
        expect(find.text('Original choice'), findsOneWidget);
        navigator.fails = false;
        await drainUi(tester, tasks.closeAndWait);
        await frames(tester);
        expect(navigator.removals, 2);
        expect(find.text('Original choice'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        navigator.fails = false;
        await tester.pumpWidget(const SizedBox());
      }
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
  int removals = 0;
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removals++;
    if (fails) throw StateError('original selection removal failed');
    super.removeRoute(route, result);
  }
}
