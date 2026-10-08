import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:window_manager/window_manager.dart';

import 'js_ui_ownership_test.dart' show drainUi;

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
  @override
  String toString() => 'validation reference';
}

void main() {
  late JsEngine engine;
  late JsUiApi api;
  late SelectionTaskRegistry tasks;
  var exits = 0;

  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> host(WidgetTester tester, {bool window = false}) async {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    engine = JsEngine.create();
    api = JsUiApi();
    tasks = SelectionTaskRegistry();
    exits = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await drainUi(tester, tasks.closeAndWait);
      await drainUi(tester, engine.closeAndWait);
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        builder: (_, child) => SelectionTasksScope(
          registry: tasks,
          child: window ? WindowFrame(child!, onExit: () => exits++) : child!,
        ),
        home: const Scaffold(body: Text('Original application')),
      ),
    );
  }

  Future<String?> open(_Callback validator) {
    final message = <String, dynamic>{
      'function': 'showInputDialog',
      'title': 'Synchronous validation',
      'validator': validator,
    };
    try {
      return api.handleUIMessage(message, engine: engine) as Future<String?>;
    } finally {
      JSRef.freeRecursive(message);
    }
  }

  for (final reject in [false, true]) {
    testWidgets(
      'immediate validator graph frees aliases and map keys; reject=$reject',
      (tester) async {
        await host(tester);
        final reference = _Reference();
        final key = _Reference();
        final graph = <Object, Object>{
          'message': 'original validation',
          key: [reference, reference],
          'alias': reference,
        };
        final validator = _Callback((_) {
          if (reject) throw graph;
          return graph;
        });
        unawaited(open(validator));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(find.textContaining('original validation'), findsOneWidget);
        expect(reference.destroys, 1);
        expect(key.destroys, 1);
        expect(validator.calls, 1);
        expect(validator.destroys, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reject in [false, true]) {
    for (final window in [false, true]) {
      testWidgets(
        'dismissed validator Promise stays with its original host; reject=$reject window=$window',
        (tester) async {
          await host(tester, window: window);
          final pending = Completer<Object?>();
          final validator = _Callback((_) => pending.future);
          final reference = _Reference();
          var shownClosed = false;
          String? selected;
          final shown = open(validator).then<void>((value) {
            shownClosed = true;
            selected = value;
          });
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'Draft');
          await tester.tap(find.text('Confirm'));
          await frames(tester);
          expect(
            find.text(Completer<dynamic>().future.toString()),
            findsOneWidget,
          );
          expect(find.text('Synchronous validation'), findsOneWidget);
          appNavigation.rootNavigatorKey.currentState!.pop();
          await frames(tester);
          var appClosed = false;
          Future<void>? closing;
          if (window) {
            (tester.state(find.byType(WindowFrame)) as WindowListener)
                .onWindowClose();
          } else {
            closing = tasks.closeAndWait().then<void>((_) => appClosed = true);
          }
          try {
            await frames(tester);
            expect(shownClosed, isTrue);
            expect(selected, isNull);
            expect(window ? exits != 0 : appClosed, isFalse);
          } finally {
            final graph = {'message': 'later result', 'reference': reference};
            if (reject) {
              pending.completeError(
                graph,
                StackTrace.fromString('original validator'),
              );
            } else {
              pending.complete(graph);
            }
            if (closing != null) await drainUi(tester, () => closing!);
            await frames(tester);
            await shown;
          }
          expect(window ? exits : (appClosed ? 1 : 0), 1);
          expect(reference.destroys, 1);
          expect(validator.destroys, 1);
          expect(validator.calls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final reject in [false, true]) {
    testWidgets(
      'unused validator Promise releases while input remains open; reject=$reject',
      (tester) async {
        await host(tester);
        final pending = Completer<Object?>();
        final reference = _Reference();
        final validator = _Callback((_) => pending.future);
        unawaited(open(validator));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await frames(tester);
        final message = Completer<dynamic>().future.toString();
        expect(find.text(message), findsOneWidget);
        if (reject) {
          pending.completeError({
            'message': 'later rejection',
            'ref': reference,
          });
        } else {
          pending.complete({'ref': reference});
        }
        await frames(tester);
        expect(reference.destroys, 1);
        expect(find.text(message), findsOneWidget);
        expect(validator.destroys, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('validator invocation survives reentrant engine disposal', (
    tester,
  ) async {
    await host(tester);
    late _Callback validator;
    var destroyedDuringCall = -1;
    validator = _Callback((_) {
      engine.dispose();
      destroyedDuringCall = validator.destroys;
      return null;
    });
    unawaited(open(validator));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await frames(tester);
    expect(destroyedDuringCall, 0);
    expect(validator.destroys, 1);
    expect(validator.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'validator Promise is registered before synchronous application close',
    (tester) async {
      await host(tester);
      final pending = Completer<Object?>();
      var closed = false;
      Future<void>? closing;
      final validator = _Callback((_) {
        closing = tasks.closeAndWait().then<void>((_) => closed = true);
        return pending.future;
      });
      unawaited(open(validator));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      try {
        await frames(tester);
        expect(closing, isNotNull);
        expect(closed, isFalse);
      } finally {
        pending.complete(null);
        await drainUi(tester, () => closing!);
      }
      expect(validator.calls, 1);
      expect(closed, isTrue);
    },
  );
}
