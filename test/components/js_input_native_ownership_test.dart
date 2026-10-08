import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import 'js_ui_ownership_test.dart' show drainUi;

void main() {
  late JsEngine engine;
  late SelectionTaskRegistry tasks;

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
    await tester.runAsync(() async {
      if (Platform.isWindows) {
        final release = Directory('build/windows/x64/runner/Release').absolute;
        DynamicLibrary.open('${release.path}/flutter_windows.dll');
        DynamicLibrary.open('${release.path}/flutter_qjs_plugin.dll');
      }
      directory = Directory.systemTemp.createTempSync('venera-js-input-');
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
        await tester.runAsync(() async {
          final root = Directory.systemTemp.resolveSymbolicLinksSync();
          expect(
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

  for (final reject in [false, true]) {
    testWidgets(
      'native immediate validation releases its original graph; reject=$reject',
      (tester) async {
        await prepare(tester);
        engine.runCode('''
        globalThis.calls = 0;
        globalThis.inputResult = 'waiting';
        void UI.showInputDialog('Native input', () => {
          calls++;
          const fn = () => 42;
          const graph = {message:'native invalid', fn, nested:[fn, {fn}]};
          ${reject ? 'throw graph;' : 'return graph;'}
        }).then(value => { inputResult = value; });
      ''');
        await frames(tester);
        await tester.tap(find.text('Confirm'));
        await frames(tester);
        expect(find.textContaining('native invalid'), findsOneWidget);
        expect(engine.runCode('calls'), 1);
        appNavigation.rootNavigatorKey.currentState!.pop();
        await frames(tester);
        expect(engine.runCode('inputResult'), isNull);
        expect(engine.debugOwnedReferenceCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final reject in [false, true]) {
    for (final dismissed in [false, true]) {
      testWidgets(
        'native validator Promise remains owned and invalid; reject=$reject dismissed=$dismissed',
        (tester) async {
          await prepare(tester);
          engine.runCode('''
          globalThis.calls = 0;
          globalThis.inputResult = 'waiting';
          void UI.showInputDialog('Native pending input', () => {
            calls++;
            return new Promise((resolve, reject) => {
              globalThis.finish = {resolve, reject};
            });
          }).then(value => { inputResult = value; });
        ''');
          await frames(tester);
          await tester.tap(find.text('Confirm'));
          await frames(tester);
          expect(find.textContaining('Future'), findsOneWidget);
          expect(engine.runCode('calls'), 1);
          var closed = false;
          Future<void>? closing;
          if (dismissed) {
            appNavigation.rootNavigatorKey.currentState!.pop();
            await frames(tester);
            closing = tasks.closeAndWait().then<void>((_) => closed = true);
          }
          try {
            await frames(tester);
            expect(closed, isFalse);
            expect(
              engine.runCode('inputResult'),
              dismissed ? isNull : 'waiting',
            );
          } finally {
            engine.runCode('''
            const fn = () => 42;
            void finish.${reject ? 'reject' : 'resolve'}({message:'native later graph', fn, nested:[fn, {fn}]});
          ''');
            if (closing != null) await drainUi(tester, () => closing!);
            await frames(tester);
          }
          if (!dismissed) {
            expect(find.textContaining('Future'), findsOneWidget);
            expect(find.text('Native pending input'), findsOneWidget);
            appNavigation.rootNavigatorKey.currentState!.pop();
            await frames(tester);
          }
          expect(engine.runCode('inputResult'), isNull);
          expect(engine.debugOwnedReferenceCount, 0);
          expect(engine.runCode('calls'), 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final action in ['confirm', 'cancel', 'dispose', 'dispose-unbuilt']) {
    testWidgets(
      'native selection Promise completes with its original route; action=$action',
      (tester) async {
        await prepare(tester);
        engine.runCode('''
        globalThis.choice = 'waiting';
        void UI.showSelectDialog('Native selection', ['First', 'Second'], 1)
          .then(value => { choice = value; });
      ''');
        await tester.idle();
        if (action != 'dispose-unbuilt') await frames(tester);
        if (action.startsWith('dispose')) {
          await tester.pumpWidget(const SizedBox());
        } else {
          await tester.tap(
            find.text(action == 'confirm' ? 'Confirm' : 'Cancel'),
          );
        }
        await frames(tester);
        expect(engine.runCode('choice'), action == 'confirm' ? 1 : null);
        expect(engine.debugOwnedReferenceCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
