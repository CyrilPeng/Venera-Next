import 'dart:async';

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
  _Callback(this.action);
  final Object? Function() action;
  int calls = 0;
  int destroys = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return action();
  }

  @override
  void destroy() => destroys++;
}

class _Reference extends JSRef {
  int destroys = 0;
  @override
  void destroy() => destroys++;
}

Iterable<Object> _causes(Object error) sync* {
  yield error;
  if (error is SelectionCleanupFailure) {
    if (error.operationError != null) yield* _causes(error.operationError!);
    for (final failure in error.failures) {
      if (failure case (error: final Object cause, stack: final StackTrace _)) {
        yield* _causes(cause);
      } else {
        yield* _causes(failure);
      }
    }
  }
}

void main() {
  late JsUiApi api;
  late JsEngine engine;
  late SelectionTaskRegistry tasks;

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> host(WidgetTester tester) async {
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
  }

  void show(_Callback? callback) {
    final message = <String, dynamic>{
      'function': 'showLoading',
      'onCancel': ?callback,
    };
    try {
      api.handleUIMessage(message, engine: engine);
    } finally {
      JSRef.freeRecursive(message);
    }
  }

  testWidgets('unbuilt JS loading releases its original cancellation', (
    tester,
  ) async {
    await host(tester);
    final callback = _Callback(() => null);
    show(callback);
    await tester.idle();
    await tester.pumpWidget(const SizedBox());
    await frames(tester);
    expect(callback.calls, 1);
    expect(callback.destroys, 1);
    await drainUi(tester, tasks.closeAndWait);
    expect(tester.takeException(), isNull);
  });

  for (final behavior in ['none', 'resolve', 'reject']) {
    testWidgets(
      'failed JS loading removal drains actual cancellation before retry: $behavior',
      (tester) async {
        await host(tester);
        final navigator =
            appNavigation.rootNavigatorKey.currentState!
                as _FailingNavigatorState;
        final pending = Completer<Object?>();
        final callback = behavior == 'none'
            ? null
            : _Callback(() => pending.future);
        final reference = _Reference();
        show(callback);
        await frames(tester);
        Object? closeError;
        var completed = false;
        final closing = tasks.closeAndWait().then<void>(
          (_) => completed = true,
          onError: (Object error) {
            closeError = error;
            completed = true;
          },
        );
        try {
          await frames(tester);
          if (callback != null) {
            expect(callback.calls, 1);
            expect(completed, isFalse);
          }
          final graph = {
            'message': 'original cancellation rejection',
            'ref': reference,
          };
          if (behavior == 'reject') {
            pending.completeError(
              graph,
              StackTrace.fromString('original cancellation stack'),
            );
          } else {
            pending.complete(behavior == 'resolve' ? graph : null);
          }
          await drainUi(tester, () => closing);
          expect(closeError, isA<SelectionCleanupFailure>());
          expect(_causes(closeError!), contains(same(navigator.failure)));
          if (behavior == 'reject') {
            expect(
              _causes(closeError!).whereType<Map>().any(
                (value) =>
                    value['message'] == 'original cancellation rejection',
              ),
              isTrue,
            );
          }
          if (callback != null) {
            expect(callback.destroys, 1);
            expect(reference.destroys, 1);
          }
          expect(navigator.removals, 1);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
          navigator.fails = false;
          await drainUi(tester, tasks.closeAndWait);
          await frames(tester);
          expect(navigator.removals, 2);
          expect(find.byType(LinearProgressIndicator), findsNothing);
          if (callback != null) expect(callback.calls, 1);
          expect(tester.takeException(), isNull);
        } finally {
          if (!pending.isCompleted) pending.complete(null);
          navigator.fails = false;
          await tester.pumpWidget(const SizedBox());
          await frames(tester);
        }
      },
    );
  }
}

class _FailingNavigator extends Navigator {
  const _FailingNavigator({super.key, super.onGenerateRoute});
  @override
  NavigatorState createState() => _FailingNavigatorState();
}

class _FailingNavigatorState extends NavigatorState {
  bool fails = true;
  int removals = 0;
  final failure = StateError('original loading route removal failed');
  @override
  void removeRoute<T extends Object?>(Route<T> route, [T? result]) {
    removals++;
    if (fails) throw failure;
    super.removeRoute(route, result);
  }
}
