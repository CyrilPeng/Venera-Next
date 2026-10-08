import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import 'js_ui_ownership_test.dart' show drainUi;

void main() {
  late JsEngine engine;
  late SelectionTaskRegistry tasks;
  final messages = <String>[];

  Future<void> frames(WidgetTester tester) async {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> prepare(WidgetTester tester) async {
    rootBundle.clear();
    final previous = (
      initialized: App.isInitialized,
      version: App.version,
      language: appdata.settings['language'],
      muted: Log.isMuted,
    );
    late Directory directory;
    tasks = SelectionTaskRegistry();
    messages.clear();
    registerShowMessageHandler((_, message) => messages.add(message));
    await tester.runAsync(() async {
      if (Platform.isWindows) {
        final release = Directory('build/windows/x64/runner/Release').absolute;
        DynamicLibrary.open('${release.path}/flutter_windows.dll');
        DynamicLibrary.open('${release.path}/flutter_qjs_plugin.dll');
      }
      directory = Directory.systemTemp.createTempSync('venera-js-ui-owner-');
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      App.isInitialized = false;
      App.version = '9.0.0';
      appdata.settings['language'] = 'en-US';
      Log.isMuted = true;
      final script = await File('assets/init.js').readAsBytes();
      engine = JsEngine.create(
        loadInitScript: () async => script,
        uiMessageHandler: JsUiApi(),
      );
      await engine.init();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      try {
        engine.runCode('void globalThis.finish?.resolve(null)');
        await drainUi(tester, tasks.closeAndWait);
        await drainUi(tester, engine.closeAndWait);
      } finally {
        App.isInitialized = previous.initialized;
        App.version = previous.version;
        appdata.settings['language'] = previous.language;
        Log.isMuted = previous.muted;
        registerShowMessageHandler((_, _) {});
        await tester.runAsync(() async {
          final root = Directory.systemTemp.resolveSymbolicLinksSync();
          expectSync(
            directory.resolveSymbolicLinksSync(),
            startsWith('$root${Platform.pathSeparator}'),
          );
          await directory.delete(recursive: true);
        });
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigation.rootNavigatorKey,
        builder: (_, child) =>
            SelectionTasksScope(registry: tasks, child: child!),
        home: const Scaffold(body: Text('Original application')),
      ),
    );
  }

  for (final loading in [false, true]) {
    for (final reject in [false, true]) {
      testWidgets(
        'native dismissed callback joins its Promise and releases graph; loading=$loading reject=$reject',
        (tester) async {
          await prepare(tester);
          engine.runCode('''
            globalThis.calls = 0;
            const action = () => {
              calls++;
              return new Promise((resolve, reject) => {
                globalThis.finish = {resolve, reject};
              });
            };
            void ${loading ? 'UI.showLoading(action)' : "UI.showDialog('Owned native dialog', 'Content', [{text:'Run native action', callback:action}])"};
          ''');
          await frames(tester);
          await tester.tap(find.text(loading ? 'Cancel' : 'Run native action'));
          await frames(tester);
          expectSync(engine.runCode('calls'), 1);
          if (!loading) appNavigation.rootNavigatorKey.currentState!.pop();
          await frames(tester);
          var closed = false;
          final closing = tasks.closeAndWait().then<void>((_) => closed = true);
          try {
            await frames(tester);
            expectSync(closed, isFalse);
          } finally {
            engine.runCode('''
              const fn = () => 42;
              void finish.${reject ? 'reject' : 'resolve'}({message:'original result', fn, nested:[fn, {fn}]});
            ''');
            await drainUi(tester, () => closing);
          }
          expectSync(engine.debugOwnedReferenceCount, 0);
          expectSync(messages, isEmpty);
          expectSync(engine.runCode('calls'), 1);
          expectSync(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final reject in [false, true]) {
    testWidgets(
      'native unbuilt loading cancellation stays with its original owner; reject=$reject',
      (tester) async {
        await prepare(tester);
        engine.runCode('''
        globalThis.calls = 0;
        void UI.showLoading(() => {
          calls++;
          return new Promise((resolve, reject) => {
            globalThis.finish = {resolve, reject};
          });
        });
      ''');
        await tester.idle();
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
        var closed = false;
        final closing = tasks.closeAndWait().then<void>((_) => closed = true);
        try {
          await frames(tester);
          expectSync(engine.runCode('calls'), 1);
          expectSync(closed, isFalse);
        } finally {
          engine.runCode('''
          const fn = () => 42;
          void finish.${reject ? 'reject' : 'resolve'}({message:'original unbuilt cancellation', fn, nested:[fn, {fn}]});
        ''');
          await drainUi(tester, () => closing);
        }
        expectSync(engine.debugOwnedReferenceCount, 0);
        expectSync(engine.runCode('calls'), 1);
        expectSync(closed, isTrue);
        expectSync(messages, isEmpty);
        expectSync(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('native UI callbacks belong to the emitting independent engine', (
    tester,
  ) async {
    await prepare(tester);
    engine.runCode('''
      globalThis.calls = 0;
      void UI.showDialog('Original engine', 'Content', [{text:'Run original', callback: () => {
        calls++;
        return {unused: () => 42};
      }}]);
    ''');
    await frames(tester);
    await drainUi(tester, JsEngine().closeAndWait);
    await tester.tap(find.text('Run original'));
    await frames(tester);
    expectSync(engine.runCode('calls'), 1);
    expectSync(find.text('Original engine'), findsNothing);
    expectSync(messages, isEmpty);
    expectSync(engine.debugOwnedReferenceCount, 0);
  });
}
