import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import 'js_ui_ownership_test.dart' show drainUi;

class _Callback extends JSInvokable {
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) => null;
  @override
  void destroy() => destroys++;
}

void main() {
  late JsEngine engine;
  late JsUiApi api;
  late SelectionTaskRegistry tasks;

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> host(WidgetTester tester, {bool removalFailure = false}) async {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    engine = JsEngine.create();
    api = JsUiApi();
    tasks = SelectionTaskRegistry();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      try {
        await drainUi(tester, tasks.closeAndWait);
      } finally {
        await drainUi(tester, engine.closeAndWait);
        appdata.settings['language'] = language;
        Log.isMuted = muted;
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: removalFailure ? null : appNavigation.rootNavigatorKey,
        builder: (_, child) => SelectionTasksScope(
          registry: tasks,
          child: removalFailure
              ? _FailingNavigator(
                  key: appNavigation.rootNavigatorKey,
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
                )
              : child!,
        ),
        home: const Scaffold(body: Text('Original host')),
      ),
    );
  }

  Future<void> show(_Callback? callback) {
    final message = <String, dynamic>{
      'function': 'showDialog',
      'title': 'Original dialog',
      'content': 'Dialog content',
      'actions': [
        if (callback != null) {'text': 'Run action', 'callback': callback},
      ],
    };
    try {
      return api.handleUIMessage(message, engine: engine) as Future<void>;
    } finally {
      JSRef.freeRecursive(message);
    }
  }

  for (final withAction in [false, true]) {
    testWidgets(
      'unbuilt JS dialog completes when its Navigator is disposed; action=$withAction',
      (tester) async {
        await host(tester);
        final callback = withAction ? _Callback() : null;
        var completed = false;
        final shown = show(callback).then<void>((_) => completed = true);
        await tester.idle();
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
        expect(completed, isTrue);
        if (callback != null) expect(callback.destroys, 1);
        await shown;
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed JS dialog removal ends waiters and retains the route for retry',
    (tester) async {
      await host(tester, removalFailure: true);
      final navigator =
          appNavigation.rootNavigatorKey.currentState!
              as _FailingNavigatorState;
      final callback = _Callback();
      Object? presentationError;
      var presentationEnded = false;
      final shown = show(callback).then<void>(
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
        expect(callback.destroys, 1);
        expect(navigator.removals, 1);
        expect(find.text('Original dialog'), findsOneWidget);
        navigator.fails = false;
        await drainUi(tester, tasks.closeAndWait);
        await frames(tester);
        expect(navigator.removals, 2);
        expect(find.text('Original dialog'), findsNothing);
        expect(callback.destroys, 1);
        expect(tester.takeException(), isNull);
      } finally {
        navigator.fails = false;
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
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
    if (fails) throw StateError('original JS dialog removal failed');
    super.removeRoute(route, result);
  }
}
