import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/js_ui.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';

void main() {
  var available = false;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      DynamicLibrary.open('$build/flutter_windows.dll');
      DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
    available = true;
  } catch (_) {}
  group(
    'real JS UI bridge',
    () {
      testWidgets(
        'dialog, loading and input callbacks release native references',
        (tester) async {
          rootBundle.clear();
          final language = appdata.settings['language'];
          appdata.settings['language'] = 'en-US';
          final directory = Directory.systemTemp.createTempSync(
            'venera-js-ui-',
          );
          App.dataPath = directory.path;
          App.cachePath = directory.path;
          final engine = JsEngine();
          await tester.runAsync(() async {
            JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
            await engine.init();
          });
          engine.bindUiMessageHandler(JsUiApi());
          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: appNavigation.rootNavigatorKey,
                home: const Scaffold(),
              ),
            );
            engine.runCode('''
          globalThis.actionCount = 0;
          UI.showDialog('Native dialog', 'Content', [{text:'Run', callback: async () => {
            globalThis.actionCount++; return {ignored: () => 1};
          }}]);
        ''');
            await tester.pumpAndSettle();
            await tester.tap(find.text('Run'));
            await tester.runAsync(() => pumpEventQueue());
            await tester.pumpAndSettle();
            expect(engine.runCode('globalThis.actionCount'), 1);
            engine.runCode('''
          globalThis.cancelCount = 0;
          UI.showLoading(async () => { globalThis.cancelCount++; return {ignored: () => 1}; });
        ''');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            await tester.tap(find.text('Cancel'));
            await tester.runAsync(() => pumpEventQueue());
            await tester.pumpAndSettle();
            expect(engine.runCode('globalThis.cancelCount'), 1);
            final input = engine.runCode(
              "UI.showInputDialog('Native input', (value) => value === 'valid' ? null : 'Invalid')",
            );
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextField), 'valid');
            await tester.tap(find.text('Confirm'));
            await tester.runAsync(() => pumpEventQueue());
            await tester.pumpAndSettle();
            Object? inputResult;
            var inputCompleted = false;
            (input as Future).then((value) {
              inputResult = value;
              inputCompleted = true;
            });
            for (var i = 0; i < 20 && !inputCompleted; i++) {
              await tester.runAsync(() => pumpEventQueue());
              await tester.pump();
            }
            expect(inputCompleted, isTrue);
            expect(inputResult, 'valid');
            final abandoned = engine.runCode(
              "UI.showInputDialog('Unmount input', () => null)",
            );
            await tester.pumpAndSettle();
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            Object? abandonedResult;
            var abandonedCompleted = false;
            (abandoned as Future).then((value) {
              abandonedResult = value;
              abandonedCompleted = true;
            });
            for (var i = 0; i < 20 && !abandonedCompleted; i++) {
              await tester.runAsync(() => pumpEventQueue());
              await tester.pump();
            }
            expect(abandonedCompleted, isTrue);
            expect(abandonedResult, isNull);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            final closing = engine.closeAndWait();
            await tester.pumpAndSettle();
            await closing; // QuickJS reports leaked native references here.
            appdata.settings['language'] = language;
            directory.deleteSync(recursive: true);
          }
        },
      );
    },
    skip: available
        ? false
        : 'QuickJS native library unavailable; run with platform build DLLs on PATH.',
  );
}
