import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';

class _Callback extends JSInvokable {
  _Callback(this.action);
  final dynamic Function(List args) action;
  int calls = 0;
  int destroyed = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return action(args);
  }

  @override
  void destroy() => destroyed++;
}

void main() {
  late JsUiApi api;
  final messages = <String>[];
  setUp(() {
    rootBundle.clear();
    final language = appdata.settings['language'];
    final muted = Log.isMuted;
    appdata.settings['language'] = 'en-US';
    Log.isMuted = true;
    messages.clear();
    registerShowMessageHandler((context, message) => messages.add(message));
    addTearDown(() {
      appdata.settings['language'] = language;
      Log.isMuted = muted;
      registerShowMessageHandler((context, message) {});
    });
    api = JsUiApi();
  });
  Future<void> host(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
  );
  dynamic invoke(Map<String, dynamic> message) {
    try {
      return api.handleUIMessage(message);
    } finally {
      JSRef.freeRecursive(message);
    } // Same borrowing rule as the JS bridge.
  }

  Future<void> finishFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final dismissal in ['button', 'back', 'barrier', 'unmount']) {
    testWidgets('dialog callback release on $dismissal', (tester) async {
      await host(tester);
      final callback = _Callback((args) => null);
      final result = invoke({
        'function': 'showDialog',
        'title': 'Dialog',
        'content': 'Content',
        'actions': [
          {'text': 'Run', 'callback': callback},
        ],
      });
      await tester.pumpAndSettle();
      expect(callback.destroyed, 0);
      switch (dismissal) {
        case 'button':
          await tester.tap(find.text('Run'));
        case 'back':
          App.rootNavigatorKey.currentState!.pop();
        case 'barrier':
          await tester.tapAt(const Offset(1, 1));
        case 'unmount':
          await tester.pumpWidget(const SizedBox());
      }
      await finishFrames(tester);
      await result;
      expect(callback.destroyed, 1);
      expect(callback.calls, dismissal == 'button' ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dismissal in [
    'button',
    'back',
    'barrier',
    'finished',
    'unmount',
  ]) {
    testWidgets('loading callback and id release on $dismissal', (
      tester,
    ) async {
      await host(tester);
      final callback = _Callback((args) => null);
      final id = invoke({'function': 'showLoading', 'onCancel': callback});
      await finishFrames(tester);
      switch (dismissal) {
        case 'button':
          await tester.tap(find.text('Cancel'));
        case 'back':
          App.rootNavigatorKey.currentState!.pop();
        case 'barrier':
          await tester.tapAt(const Offset(1, 1));
        case 'finished':
          invoke({'function': 'cancelLoading', 'id': id});
        case 'unmount':
          await tester.pumpWidget(const SizedBox());
      }
      await finishFrames(tester);
      expect(callback.calls, dismissal == 'finished' ? 0 : 1);
      expect(callback.destroyed, 1);
      if (dismissal == 'unmount') await host(tester);
      final nextId = invoke({'function': 'showLoading'});
      expect(nextId, id);
      invoke({'function': 'cancelLoading', 'id': nextId});
      await finishFrames(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('input validator remains live through retries then releases', (
    tester,
  ) async {
    await host(tester);
    final validator = _Callback(
      (args) => args.single == 'valid' ? null : 'Invalid value',
    );
    final result = invoke({
      'function': 'showInputDialog',
      'title': 'Input',
      'validator': validator,
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'bad');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid value'), findsOneWidget);
    expect(validator.destroyed, 0);
    await tester.enterText(find.byType(TextField), 'valid');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await result, 'valid');
    expect(validator.destroyed, 1);
  });

  testWidgets('input unmount completes request and releases validator', (
    tester,
  ) async {
    await host(tester);
    final validator = _Callback((args) => null);
    final result = invoke({
      'function': 'showInputDialog',
      'title': 'Input',
      'validator': validator,
    });
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(await result, isNull);
    expect(validator.destroyed, 1);
  });

  testWidgets('validator exception stays in input dialog and can retry', (
    tester,
  ) async {
    await host(tester);
    final validator = _Callback((args) {
      if (args.single != 'valid') throw StateError('validation failed');
      return null;
    });
    final result = invoke({
      'function': 'showInputDialog',
      'title': 'Input',
      'validator': validator,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('validation failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'valid');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await result, 'valid');
    expect(validator.destroyed, 1);
  });

  for (final fail in [false, true]) {
    testWidgets('late action completion after dismissal; fail=$fail', (
      tester,
    ) async {
      await host(tester);
      final completion = Completer<void>();
      final callback = _Callback((args) => completion.future);
      final result = invoke({
        'function': 'showDialog',
        'title': 'Dialog',
        'content': 'Content',
        'actions': [
          {'text': 'Run', 'callback': callback},
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pump();
      App.rootNavigatorKey.currentState!.pop();
      await finishFrames(tester);
      await result;
      if (fail) {
        completion.completeError(StateError('late'));
      } else {
        completion.complete();
      }
      await tester.pump();
      expect(callback.destroyed, 1);
      expect(messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
