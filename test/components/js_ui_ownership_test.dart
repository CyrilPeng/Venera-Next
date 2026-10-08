import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/navigation_admission.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

class _Callback extends JSInvokable {
  _Callback(this.action);
  final Object? Function(List<dynamic>) action;
  int calls = 0;
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return action(List<dynamic>.from(args));
  }

  @override
  void destroy() => destroys++;
}

class _Reference extends JSRef {
  int destroys = 0;
  @override
  void destroy() => destroys++;
}

Future<void> drainUi(
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
  expectSync(done, isTrue, reason: 'The original UI work did not settle.');
  await result;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

void main() {
  late JsUiApi api;
  late JsEngine engine;
  late SelectionTaskRegistry tasks;
  var allowed = true;
  final messages = <String>[];
  final navigator = appNavigation.rootNavigatorKey;

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> host(WidgetTester tester) async {
    rootBundle.clear();
    tasks = SelectionTaskRegistry();
    engine = JsEngine.create();
    api = JsUiApi();
    allowed = true;
    messages.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    registerShowMessageHandler((_, message) => messages.add(message));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await drainUi(tester, tasks.closeAndWait);
      await drainUi(tester, engine.closeAndWait);
      registerShowMessageHandler((_, _) {});
      appdata.settings['language'] = language;
      Log.isMuted = muted;
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => NavigationAdmission(
          allowsNavigation: () => allowed,
          child: SelectionTasksScope(registry: tasks, child: child!),
        ),
        home: const Scaffold(body: Text('Home')),
      ),
    );
  }

  dynamic invoke(Map<String, dynamic> message) {
    try {
      return api.handleUIMessage(message, engine: engine);
    } finally {
      JSRef.freeRecursive(message);
    }
  }

  Future<void> showAction(WidgetTester tester, _Callback callback) async {
    final shown =
        invoke({
              'function': 'showDialog',
              'title': 'Original dialog',
              'content': 'Content',
              'actions': [
                {'text': 'Run action', 'callback': callback},
              ],
            })
            as Future<void>;
    unawaited(shown);
    await tester.pumpAndSettle();
  }

  for (final fail in [false, true]) {
    testWidgets('covered dialog retains its route and notice; failure=$fail', (
      tester,
    ) async {
      await host(tester);
      final completion = Completer<Object?>();
      final callback = _Callback((_) => completion.future);
      await showAction(tester, callback);
      await tester.tap(find.text('Run action'));
      await tester.pump();
      final cover = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Cover')),
      );
      unawaited(navigator.currentState!.push(cover));
      await frames(tester);
      if (fail) {
        completion.completeError(StateError('late callback'));
      } else {
        completion.complete(null);
      }
      await frames(tester);
      expectSync(cover.isCurrent, isTrue);
      expectSync(messages, isEmpty);
      expectSync(callback.calls, 1);
    });
  }

  for (final loading in [false, true]) {
    testWidgets(
      'original application joins dismissed callback; loading=$loading',
      (tester) async {
        await host(tester);
        final completion = Completer<Object?>();
        final callback = _Callback((_) => completion.future);
        if (loading) {
          invoke({'function': 'showLoading', 'onCancel': callback});
          await frames(tester);
          await tester.tap(find.text('Cancel'));
        } else {
          await showAction(tester, callback);
          await tester.tap(find.text('Run action'));
        }
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final closing = tasks.closeAndWait().then((_) => closed = true);
        var closedBeforeCompletion = false;
        try {
          await tester.pump();
          closedBeforeCompletion = closed;
        } finally {
          completion.complete(null);
          await frames(tester);
          await closing;
        }
        expectSync(callback.calls, 1);
        expectSync(closedBeforeCompletion, isFalse);
        expectSync(callback.destroys, 1);
      },
    );
  }

  testWidgets('frozen dialog rejects a retained button callback', (
    tester,
  ) async {
    await host(tester);
    final callback = _Callback((_) => null);
    await showAction(tester, callback);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Run action'),
    );
    allowed = false;
    button.onPressed!();
    await frames(tester);
    expectSync(callback.calls, 0);
    expectSync(messages, isEmpty);
  });

  testWidgets('busy state blocks synchronous callback reentry', (tester) async {
    await host(tester);
    VoidCallback? press;
    late final _Callback callback;
    callback = _Callback((_) {
      if (callback.calls == 1) press!();
      return Future<Object?>.value(null);
    });
    await showAction(tester, callback);
    press = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Run action'))
        .onPressed;
    press!();
    await frames(tester);
    expectSync(callback.calls, 1);
  });

  testWidgets('rejected action releases distinct reference wrappers once', (
    tester,
  ) async {
    await host(tester);
    final reference = _Reference();
    final callback = _Callback((_) {
      throw {
        'message': 'rejected graph',
        'value': reference,
        'alias': reference,
      };
    });
    await showAction(tester, callback);
    await tester.tap(find.text('Run action'));
    await frames(tester);
    expectSync(reference.destroys, 1);
    expectSync(callback.calls, 1);
    expectSync(messages.single, contains('rejected graph'));
  });

  testWidgets('loading cancellation rejects synchronous repeated presses', (
    tester,
  ) async {
    await host(tester);
    VoidCallback? press;
    late final _Callback callback;
    callback = _Callback((_) {
      if (callback.calls == 1) press!();
      return null;
    });
    invoke({'function': 'showLoading', 'onCancel': callback});
    await frames(tester);
    press = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Cancel'))
        .onPressed;
    press!();
    await frames(tester);
    expectSync(callback.calls, 1);
    expectSync(callback.destroys, 1);
  });

  testWidgets('a retired loading cancellation cannot release a reused id', (
    tester,
  ) async {
    await host(tester);
    final completion = Completer<Object?>();
    final callback = _Callback((_) => completion.future);
    final first = invoke({'function': 'showLoading', 'onCancel': callback});
    await frames(tester);
    await tester.tap(find.text('Cancel'));
    await frames(tester);
    final next = invoke({'function': 'showLoading'});
    expectSync(next, first);
    await frames(tester);
    completion.complete(null);
    await frames(tester);
    invoke({'function': 'cancelLoading', 'id': next});
    await frames(tester);
    expectSync(find.byType(LinearProgressIndicator), findsNothing);
    expectSync(callback.destroys, 1);
  });

  testWidgets(
    'immediate programmatic loading completion does not invoke cancel',
    (tester) async {
      await host(tester);
      final callback = _Callback((_) => null);
      final id = invoke({'function': 'showLoading', 'onCancel': callback});
      invoke({'function': 'cancelLoading', 'id': id});
      await frames(tester);
      expectSync(callback.calls, 0);
      expectSync(callback.destroys, 1);
      expectSync(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'busy action keeps its accessible name and disables repeat input',
    (tester) async {
      await host(tester);
      final semantics = tester.ensureSemantics();
      final completion = Completer<Object?>();
      await showAction(tester, _Callback((_) => completion.future));
      await tester.tap(find.text('Run action'));
      await tester.pump();
      try {
        expectSync(find.bySemanticsLabel('Run action'), findsOneWidget);
        final button = tester.widget<TextButton>(find.byType(TextButton));
        expectSync(button.onPressed, isNull);
      } finally {
        completion.complete(null);
        await frames(tester);
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'input validator retains its synchronous Future-to-string contract',
    (tester) async {
      await host(tester);
      var completed = false;
      final callback = _Callback((_) => Future<Object?>.value(null));
      final result =
          invoke({
                'function': 'showInputDialog',
                'title': 'Synchronous validation',
                'validator': callback,
              })
              as Future<String?>;
      final observed = result.then((_) => completed = true);
      await frames(tester);
      await tester.tap(find.text('Confirm'));
      await frames(tester);
      expectSync(completed, isFalse);
      expectSync(find.textContaining('Future'), findsOneWidget);
      navigator.currentState!.pop();
      await frames(tester);
      await observed;
      expectSync(callback.calls, 1);
      expectSync(callback.destroys, 1);
    },
  );
}
