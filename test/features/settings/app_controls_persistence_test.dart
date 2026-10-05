import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/settings/app_controls.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('app-controls-');
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  final previousPath = App.dataPath;
  App.dataPath = root.path;
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['language'] = 'en-US';
  appdata.settings['cacheSize'] = 2048;
  appdata.settings['authorizationRequired'] = false;
  registerShowMessageHandler((_, _) {});
  addTearDown(() {
    previous.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = previousPath;
    root.deleteSync(recursive: true);
  });
  return root;
}

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? error;
  operation.then(
    (_) => done = true,
    onError: (Object e) {
      done = true;
      error = e;
    },
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done, isTrue);
  expect(error, isNull);
  await tester.pump();
}

Map _saved(Directory root) =>
    (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
            as Map)['settings']
        as Map;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

SettingsSaveState _authOwner(WidgetTester tester) =>
    tester.state<SettingsSaveState>(find.byType(AuthorizationRequiredSetting));

void _toggle(WidgetTester tester, bool value) => tester
    .widget<SwitchListTile>(find.byType(SwitchListTile))
    .onChanged!(value);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;

  testWidgets('cache validates input and back waits for queued persistence', (
    tester,
  ) async {
    final root = _prepare();
    await tester.pumpWidget(_host(const CacheLimitSetting()));
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    for (final invalid in [
      '-1',
      '1.5',
      '8796093022208',
      '9999999999999999999999',
    ]) {
      await tester.enterText(find.byType(TextField), invalid);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pump();
      expect(find.text('Invalid input'), findsOneWidget);
    }
    await tester.enterText(find.byType(TextField), '0');
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    final dialogContext = tester.element(find.byType(TextField));
    unawaited(Navigator.of(dialogContext).maybePop());
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(appdata.settings['cacheSize'], 2048);
    expect(CacheManager.instance, isNull);
    release.complete();
    await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(_saved(root)['cacheSize'], 0);
    expect(CacheManager.instance, isNull);
  });

  testWidgets('cache persistence failure preserves input for retry', (
    tester,
  ) async {
    final root = _prepare();
    final blocked = Directory('${root.path}/appdata.json')..createSync();
    await tester.pumpWidget(_host(const CacheLimitSetting()));
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '128');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('Retry'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '128',
    );
    blocked.deleteSync();
    await tester.tap(find.text('Retry'));
    await _flush(tester, appdata.saveData(false));
    await tester.pumpAndSettle();
    expect(_saved(root)['cacheSize'], 128);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'authorization survives removal and window waits for support and save',
    (tester) async {
      final root = _prepare();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      final support = Completer<bool>();
      var showing = true;
      var exits = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(
            child!,
            onExit: () async {
              exits++;
            },
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return showing
                    ? AuthorizationRequiredSetting(
                        checkSupport: () => support.future,
                      )
                    : const SizedBox();
              },
            ),
          ),
        ),
      );
      final owner = _authOwner(tester);
      _toggle(tester, true);
      await tester.pump();
      expect(appdata.settings['authorizationRequired'], isFalse);
      update(() => showing = false);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      support.complete(true);
      await _flush(tester, owner.waitForSettingsSave());
      for (var i = 0; i < 20 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(exits, 1);
      expect(_saved(root)['authorizationRequired'], isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'old unsupported response cannot override newer enabled request',
    (tester) async {
      final root = _prepare();
      final slow = Completer<bool>();
      var checks = 0;
      await tester.pumpWidget(
        _host(
          AuthorizationRequiredSetting(
            checkSupport: () =>
                ++checks == 1 ? slow.future : Future.value(true),
          ),
        ),
      );
      _toggle(tester, true);
      _toggle(tester, false);
      _toggle(tester, true);
      await _flush(tester, appdata.saveData(false));
      slow.complete(false);
      await _flush(tester, _authOwner(tester).waitForSettingsSave());
      expect(checks, 2);
      expect(_saved(root)['authorizationRequired'], isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    },
  );

  testWidgets('authorization retry reuses support result after failed write', (
    tester,
  ) async {
    final root = _prepare();
    final blocked = Directory('${root.path}/appdata.json')..createSync();
    var checks = 0;
    await tester.pumpWidget(
      _host(
        AuthorizationRequiredSetting(
          checkSupport: () async {
            checks++;
            return true;
          },
        ),
      ),
    );
    _toggle(tester, true);
    await _flush(
      tester,
      _authOwner(tester).waitForSettingsSave().catchError((Object _) {}),
    );
    expect(find.text('Retry'), findsOneWidget);
    blocked.deleteSync();
    await tester.tap(find.text('Retry'));
    await _flush(tester, _authOwner(tester).waitForSettingsSave());
    expect(checks, 1);
    expect(_saved(root)['authorizationRequired'], isTrue);
  });

  testWidgets(
    'replaced authorization provider invalidates its pending result',
    (tester) async {
      _prepare();
      final oldSupport = Completer<bool>();
      await tester.pumpWidget(
        _host(
          AuthorizationRequiredSetting(checkSupport: () => oldSupport.future),
        ),
      );
      _toggle(tester, true);
      final owner = _authOwner(tester);
      await tester.pumpWidget(
        _host(AuthorizationRequiredSetting(checkSupport: () async => false)),
      );
      oldSupport.complete(true);
      await _flush(tester, owner.waitForSettingsSave());
      expect(appdata.settings['authorizationRequired'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
