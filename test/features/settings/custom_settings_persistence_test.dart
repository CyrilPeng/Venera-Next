import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/code.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/settings/network.dart';
import 'package:venera_next/features/settings/reader.dart';
import 'package:venera_next/features/settings/reader_mode.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('custom-settings-');
  final previousPath = App.dataPath;
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
  appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
  appdata.settings['autoReaderMode'] = false;
  appdata.settings['proxy'] = 'direct';
  appdata.settings['dnsOverrides'] = <String, String>{'example.org': '1.1.1.1'};
  registerShowMessageHandler((context, message) {});
  addTearDown(() {
    App.dataPath = previousPath;
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
  return root;
}

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
  expect(finished, isTrue, reason: 'Real persistence must finish');
  expect(failure, isNull);
  await tester.pump();
}

Widget _host(Widget child, {Widget Function(BuildContext, Widget?)? builder}) =>
    MaterialApp(
      navigatorKey: appNavigation.rootNavigatorKey,
      builder: builder,
      home: OverlayWidget(Scaffold(body: child)),
    );

Map<String, dynamic> _saved(Directory root) =>
    jsonDecode(File('${root.path}/appdata.json').readAsStringSync())['settings']
        as Map<String, dynamic>;

class _SavePage extends StatefulWidget {
  const _SavePage({super.key});
  @override
  State<_SavePage> createState() => _SavePageState();
}

class _SavePageState extends SettingsSaveState<_SavePage> {
  @override
  Widget build(BuildContext context) => PopUpWidgetScaffold(
    title: 'Save owner',
    onBack: leaveSettings,
    tailing: [settingsSaveStatus],
    body: const Text('Editing'),
  );
}

void main() {
  App.dataPath = Directory.systemTemp.path;
  testWidgets(
    'closing old window does not wait for edits accepted after owner migration',
    (tester) async {
      _prepare();
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
      final ownerKey = GlobalKey<_SavePageState>();
      final oldWindow = GlobalKey();
      var moved = false;
      var exits = 0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) {
              updateHost = update;
              return Row(
                children: [
                  Expanded(
                    child: WindowFrame(
                      moved
                          ? const SizedBox.shrink()
                          : _SavePage(key: ownerKey),
                      key: oldWindow,
                      onExit: () => exits++,
                    ),
                  ),
                  Expanded(
                    child: WindowFrame(
                      moved
                          ? _SavePage(key: ownerKey)
                          : const SizedBox.shrink(),
                      onExit: () {},
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      final owner = ownerKey.currentState!;
      final oldWrite = Completer<void>(), newWrite = Completer<void>();
      final first = owner.saveSetting('a', () => oldWrite.future);
      (tester.state(find.byKey(oldWindow)) as WindowListener).onWindowClose();
      await tester.pump();
      updateHost(() => moved = true);
      await tester.pump();
      expect(ownerKey.currentState, same(owner));
      final second = owner.saveSetting('b', () => newWrite.future);
      try {
        oldWrite.complete();
        await first;
        await tester.pump();
        expect(exits, 1);
        expect(owner.savingSettings, isTrue);
      } finally {
        if (!oldWrite.isCompleted) oldWrite.complete();
        newWrite.complete();
        await Future.wait([first, second]);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'two owners of one popup wait independently and pop only their own route',
    (tester) async {
      _prepare();
      final first = GlobalKey<_SavePageState>();
      final second = GlobalKey<_SavePageState>();
      await tester.pumpWidget(_host(const Text('Home')));
      var popped = 0;
      unawaited(
        showPopUpWidget<void>(
          appNavigation.rootContext,
          Column(
            children: [
              Expanded(child: _SavePage(key: first)),
              Expanded(child: _SavePage(key: second)),
            ],
          ),
        ).then((_) => popped++),
      );
      await tester.pumpAndSettle();
      final a = Completer<void>(), b = Completer<void>();
      final sa = first.currentState!.saveSetting('a', () => a.future);
      final sb = second.currentState!.saveSetting('b', () => b.future);
      await appNavigation.rootNavigatorKey.currentState!.maybePop();
      a.complete();
      await sa;
      await tester.pump(const Duration(milliseconds: 400));
      expect(popped, 0);
      b.complete();
      await sb;
      await tester.pumpAndSettle();
      expect(popped, 1);
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('leaving a saving page cannot dismiss a newer route', (
    tester,
  ) async {
    _prepare();
    final key = GlobalKey<_SavePageState>();
    await tester.pumpWidget(_host(const Text('Home')));
    unawaited(
      showPopUpWidget<void>(appNavigation.rootContext, _SavePage(key: key)),
    );
    await tester.pumpAndSettle();
    final release = Completer<void>();
    final save = key.currentState!.saveSetting('a', () => release.future);
    final leaving = key.currentState!.leaveSettings();
    unawaited(
      showDialog<void>(
        context: appNavigation.rootContext,
        builder: (_) => const AlertDialog(content: Text('New route')),
      ),
    );
    await tester.pump();
    release.complete();
    await save;
    await leaving;
    await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    appNavigation.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Editing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(375, 812), const Size(900, 375)]) {
    testWidgets(
      'popup save failure fits $size with large text and dark reduced motion',
      (tester) async {
        _prepare();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey<_SavePageState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: _SavePage(key: key),
          ),
        );
        var failed = true;
        await key.currentState!.saveSetting('a', () async {
          if (failed) throw StateError('Retry required');
        });
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);
        expect(tester.takeException(), isNull);
        failed = false;
        await key.currentState!.retrySettingsSave();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'different failed fields retain retries and all accepted futures are awaited',
    (tester) async {
      _prepare();
      final key = GlobalKey<_SavePageState>();
      await tester.pumpWidget(_host(_SavePage(key: key)));
      final state = key.currentState!;
      final old = Completer<void>();
      final oldSave = state.saveSetting('mode', () => old.future);
      await state.saveSetting('mode', () async {});
      var drained = false;
      Object? lateFailure;
      final drain = state
          .waitForSettingsSave()
          .catchError((Object error) {
            lateFailure = error;
          })
          .whenComplete(() => drained = true);
      await tester.pump();
      expect(drained, isFalse);
      final superseded = StateError('superseded failure');
      old.completeError(superseded);
      await oldSave;
      await drain;
      expect(lateFailure, same(superseded));
      expect(state.hasSettingsSaveError, isTrue);
      await state.retrySettingsSave();
      expect(state.hasSettingsSaveError, isFalse);

      final failure = StateError('mode failure');
      var attempts = 0;
      await state.saveSetting('mode', () async {
        if (++attempts == 1) throw failure;
      });
      await state.saveSetting('brightness', () async {});
      await expectLater(state.waitForSettingsSave(), throwsA(same(failure)));
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
      await state.retrySettingsSave();
      await state.waitForSettingsSave();
      expect(attempts, 2);
      expect(state.hasSettingsSaveError, isFalse);
      final firstFailure = StateError('first');
      final secondFailure = StateError('second');
      var fail = true;
      await state.saveSetting('one', () async {
        if (fail) throw firstFailure;
      });
      await state.saveSetting('two', () async {
        if (fail) throw secondFailure;
      });
      await expectLater(
        state.waitForSettingsSave(),
        throwsA(
          isA<SettingsSaveFailure>().having(
            (error) => error.failures.map((failure) => failure.error).toList(),
            'original failures',
            [same(firstFailure), same(secondFailure)],
          ),
        ),
      );
      fail = false;
      await state.retrySettingsSave();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final back in ['button', 'barrier']) {
    testWidgets(
      'popup $back waits for the real save through the inner navigator',
      (tester) async {
        final root = _prepare();
        final key = GlobalKey<_SavePageState>();
        await tester.pumpWidget(_host(const Text('Home')));
        var popped = false;
        unawaited(
          showPopUpWidget<void>(
            appNavigation.rootContext,
            _SavePage(key: key),
          ).then((_) => popped = true),
        );
        await tester.pumpAndSettle();
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final save = key.currentState!.saveSetting(
          'proxy',
          () => appdata.updateSettings((draft) {
            draft['proxy'] = 'system';
          }),
        );
        await tester.pump();
        if (back == 'button') {
          await tester.tap(find.byIcon(Icons.arrow_back_sharp));
        } else {
          await tester.tapAt(const Offset(5, 5));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(popped, isFalse);
        expect(find.text('Editing'), findsOneWidget);
        expect(appdata.settings['proxy'], 'direct');
        release.complete();
        await _flush(tester, Future.wait([exclusive, save]));
        await tester.pumpAndSettle();
        expect(_saved(root)['proxy'], 'system');
        expect(popped, isTrue);
        expect(find.text('Home'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'window waits for every save after the custom page is forcibly removed',
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
      final key = GlobalKey<_SavePageState>();
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              updateHost = setState;
              return showing ? _SavePage(key: key) : const Text('Removed');
            },
          ),
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final save = key.currentState!.saveSetting(
        'proxy',
        () => appdata.updateSettings((draft) {
          draft['proxy'] = 'system';
        }),
        onSaved: () => callbacks++,
      );
      updateHost(() => showing = false);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, save]));
      await tester.pump();
      expect(exits, 1);
      expect(callbacks, 0);
      expect(_saved(root)['proxy'], 'system');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reader mode menu rejects a result after its comic target changes',
    (tester) async {
      _prepare();
      var comic = 'one';
      late StateSetter updateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              updateHost = setState;
              return ReaderModeSettings(comicId: comic, sourceKey: 'local');
            },
          ),
        ),
      );
      await tester.tap(find.text('Reading mode for this comic'));
      await tester.pumpAndSettle();
      updateHost(() => comic = 'two');
      await tester.pump();
      await tester.tap(find.byType(SimpleDialogOption).last);
      await tester.pumpAndSettle();
      expect(appdata.settings.comicReaderModeOverride('one', 'local'), isNull);
      expect(appdata.settings.comicReaderModeOverride('two', 'local'), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reader mode waits for admission and a replaced target receives no success callback',
    (tester) async {
      final root = _prepare();
      var comic = 'one';
      var callbacks = 0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              updateHost = setState;
              return ReaderModeSettings(
                comicId: comic,
                sourceKey: 'local',
                onChanged: () => callbacks++,
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Reading mode for this comic'));
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.byType(SimpleDialogOption).last);
      await tester.pump(const Duration(milliseconds: 400));
      updateHost(() => comic = 'two');
      await tester.pump();
      expect(appdata.settings.comicReaderModeOverride('one', 'local'), isNull);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(
        appdata.settings.comicReaderModeOverride('one', 'local'),
        isNotNull,
      );
      expect(appdata.settings.comicReaderModeOverride('two', 'local'), isNull);
      expect(_saved(root)['comicSpecificSettings'], isNotEmpty);
      expect(callbacks, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'DNS edits persist before disposal and removing a row preserves the other controllers',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(_host(const NetworkSettings()));
      await tester.tap(find.text('DNS Overrides'));
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.enterText(find.byType(TextField).at(1), '2.2.2.2');
      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(2), 'other.org');
      await tester.enterText(find.byType(TextField).at(3), '3.3.3.3');
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'other.org',
      );
      expect(appdata.settings['dnsOverrides'], {'example.org': '1.1.1.1'});
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(_saved(root)['dnsOverrides'], {'other.org': '3.3.3.3'});
      expect(find.text('DNS Overrides'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'proxy editor restores credentials and retains draft across mode switches',
    (tester) async {
      final root = _prepare();
      appdata.settings['proxy'] = 'user:pass@proxy.test:+07897';
      await tester.pumpWidget(_host(const NetworkSettings()));
      await tester.tap(find.text('Proxy'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .map((field) => field.initialValue),
        ['proxy.test', '+07897', 'user', 'pass'],
      );
      await tester.enterText(find.byType(TextFormField).first, 'edited.test');
      await tester.tap(find.text('System'));
      await _flush(tester, appdata.saveData(false));
      expect(_saved(root)['proxy'], 'system');
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextFormField>(find.byType(TextFormField))
            .map((field) => field.initialValue),
        ['edited.test', '+07897', 'user', 'pass'],
      );
      await tester.tap(find.text('Save'));
      await _flush(tester, appdata.saveData(false));
      await tester.pumpAndSettle();
      expect(_saved(root)['proxy'], 'user:pass@edited.test:+07897');
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.text('Proxy'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .initialValue,
        'edited.test',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual proxy keeps text and stays open on failure until retry succeeds',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(_host(const NetworkSettings()));
      await tester.tap(find.text('Proxy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manual'));
      await tester.pump();
      await tester.enterText(find.byType(TextFormField).first, 'localhost');
      await tester.enterText(find.byType(TextFormField).at(1), '7897');
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('localhost'), findsOneWidget);
      blocked.deleteSync();
      await tester.tap(find.text('Retry'));
      await _flush(tester, appdata.saveData(false));
      expect(_saved(root)['proxy'], 'localhost:7897');
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_back_sharp));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R2 malformed image processing preferences open without rewriting raw data',
    (tester) async {
      final root = _prepare();
      appdata.settings['customImageProcessing'] = ['invalid'];
      appdata.settings['enableCustomImageProcessing'] = 'invalid';
      await tester.pumpWidget(_host(const ReaderSettings()));
      await tester.scrollUntilVisible(
        find.text('Custom Image Processing'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      tester
          .widget<CallbackSetting>(
            find.ancestor(
              of: find.text('Custom Image Processing'),
              matching: find.byType(CallbackSetting),
            ),
          )
          .callback();
      await tester.pumpAndSettle();
      expect(find.byType(CodeEditor), findsOneWidget);
      expect(appdata.settings['customImageProcessing'], ['invalid']);
      expect(appdata.settings['enableCustomImageProcessing'], 'invalid');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Reset'));
      await _flush(tester, appdata.saveData(false));
      expect(
        _saved(root)['customImageProcessing'],
        defaultCustomImageProcessing,
      );
      expect(_saved(root)['enableCustomImageProcessing'], 'invalid');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'image processing reset joins the edit queue and back waits for persistence',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(_host(const ReaderSettings()));
      final scroll = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Custom Image Processing'),
        400,
        scrollable: scroll,
      );
      final setting = tester.widget<CallbackSetting>(
        find.ancestor(
          of: find.text('Custom Image Processing'),
          matching: find.byType(CallbackSetting),
        ),
      );
      setting.callback();
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester.widget<CodeEditor>(find.byType(CodeEditor)).onChanged!(
        'custom code',
      );
      await tester.pump();
      await tester.tap(find.text('Reset'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back).last);
      await tester.pump();
      expect(find.byType(CodeEditor), findsOneWidget);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      await tester.pumpAndSettle();
      expect(
        _saved(root)['customImageProcessing'],
        defaultCustomImageProcessing,
      );
      expect(find.byType(CodeEditor), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
