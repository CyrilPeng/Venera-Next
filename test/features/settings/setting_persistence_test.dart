import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/reader_preferences.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var finished = false;
  Object? failure;
  operation.then(
    (_) => finished = true,
    onError: (Object error) {
      failure = error;
      finished = true;
    },
  );
  for (var i = 0; i < 500 && !finished; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(finished, isTrue, reason: 'The real save must finish');
  expect(failure, isNull);
  await operation;
  await tester.pump();
}

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('settings-persistence-');
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  appdata.settings['showPageNumberInReader'] = true;
  appdata.settings['readerSideMargin'] = 0;
  appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
  appdata.settings['disableSyncFields'] = '';
  registerShowMessageHandler(
    (context, message) => showToast(message: message, context: context),
  );
  addTearDown(() {
    registerShowMessageHandler((context, message) {});
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
  return root;
}

Widget _host(Widget child) =>
    MaterialApp(home: OverlayWidget(Scaffold(body: child)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'switch waits for admission and reports success only after persistence',
    (tester) async {
      final root = _prepare();
      var callbacks = 0;
      await tester.pumpWidget(
        _host(
          SwitchSetting.reader(
            title: 'Page number',
            preference: ReaderPreferences.showPageNumberInReader,
            onChanged: () => callbacks++,
          ),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(appdata.settings['showPageNumberInReader'], isTrue);
      expect(callbacks, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(callbacks, 1);
      expect(
        jsonDecode(
          File('${root.path}/appdata.json').readAsStringSync(),
        )['settings']['showPageNumberInReader'],
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rapid slider changes keep the final value and window owns unmounted saves',
    (tester) async {
      final root = _prepare();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => false,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      var showing = true;
      var exits = 0;
      var callbacks = 0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigation.rootNavigatorKey,
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: StatefulBuilder(
            builder: (context, setState) {
              updateHost = setState;
              return Scaffold(
                body: showing
                    ? SliderSetting.reader(
                        title: 'Margin',
                        preference: ReaderPreferences.readerSideMargin,
                        onChanged: () => callbacks++,
                      )
                    : const Text('Closed settings'),
              );
            },
          ),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final change = tester.widget<Slider>(find.byType(Slider)).onChanged!;
      change(5);
      change(10);
      change(20);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
      expect(appdata.settings['readerSideMargin'], 0);
      updateHost(() => showing = false);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      for (var i = 0; i < 10 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(exits, 1);
      expect(callbacks, 0);
      final value = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings']['readerSideMargin'];
      expect(value, 20);
      expect(value, isA<int>());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (width, typed) in [
    for (final width in [360.0, 600.0])
      for (final typed in [false, true]) (width, typed),
  ]) {
    testWidgets(
      'nullable selector rejects a late selection for a replaced field at $width (typed=$typed)',
      (tester) async {
        _prepare();
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appdata.settings['defaultSearchTarget'] = null;
        appdata.settings['initialPage'] = '0';
        var key = 'defaultSearchTarget';
        late StateSetter updateHost;
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                if (typed) {
                  return SelectSetting.preference(
                    title: 'Choose target',
                    preference: key == 'defaultSearchTarget'
                        ? DiscoveryPreferences.defaultSearchTarget
                        : const StringPreference('initialPage', '0'),
                    optionTranslation: const {
                      '0': 'Default option',
                      'other': 'Other option',
                    },
                  );
                }
                return SelectSetting(
                  title: 'Choose target',
                  settingKey: key,
                  optionTranslation: const {
                    '0': 'Default option',
                    'other': 'Other option',
                  },
                );
              },
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(
          width < 450
              ? find.byType(ListTile)
              : find.byIcon(Icons.arrow_drop_down),
        );
        await tester.pumpAndSettle();
        updateHost(() => key = 'initialPage');
        await tester.pump();
        await tester.tap(find.text('Other option').last);
        await tester.pumpAndSettle();
        await _flush(tester, appdata.saveData(false));
        expect(appdata.settings['initialPage'], '0');
        expect(appdata.settings['defaultSearchTarget'], isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('failed save has no success callback and can be saved again', (
    tester,
  ) async {
    final root = _prepare();
    final blockedFile = Directory('${root.path}/appdata.json')..createSync();
    var callbacks = 0;
    await tester.pumpWidget(
      _host(
        SwitchSetting.reader(
          title: 'Page number',
          preference: ReaderPreferences.showPageNumberInReader,
          onChanged: () => callbacks++,
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    for (
      var i = 0;
      i < 500 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(callbacks, 0);
    expect(find.textContaining('appdata.json'), findsWidgets);
    expect(tester.takeException(), isNull);
    blockedFile.deleteSync();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await _flush(tester, appdata.saveData(false));
    expect(callbacks, 1);
    expect(File('${root.path}/appdata.json').existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
