import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/brightness.dart';
import 'package:venera_next/features/settings/reader.dart';
import 'package:venera_next/features/settings/reader_brightness.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_work.dart';

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('reader-settings-save-');
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  appdata.settings['deviceId'] = 'test-device';
  appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
  appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['autoReaderMode'] = false;
  appdata.settings['readerBrightnessEnabled'] = true;
  appdata.settings['readerBrightness'] = 50;
  addTearDown(() {
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
  return root;
}

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then(
    (_) => done = true,
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  for (var i = 0; i < 500 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done, isTrue);
  expect(failure, isNull);
}

Widget _host(Widget child, {ImageWork? work}) => MaterialApp(
  home: Scaffold(
    body: work == null ? child : SettingsSaveScope(work: work, child: child),
  ),
);

void main() {
  testWidgets(
    'device scope saves and clears only this device while preserving global values',
    (tester) async {
      _prepare();
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{
        'other-device': {'enabled': true, 'readerBrightness': 90},
      };
      await tester.pumpWidget(_host(const ReaderSettings()));
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Enable device specific settings',
            ),
          )
          .onChanged!(true);
      expect(appdata.settings.isDeviceSpecificSettingsEnabled(), isFalse);
      // The second edit must resolve the scope at its queue head, after the
      // admitted toggle, even though the live settings still use global scope.
      tester
          .widget<ReaderBrightnessControl>(find.byType(ReaderBrightnessControl))
          .onBrightnessChanged(25);
      expect(appdata.settings['readerBrightness'], 50);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(appdata.settings.isDeviceSpecificSettingsEnabled(), isTrue);
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 25);
      expect(appdata.settings['readerBrightness'], 50);
      await tester.tap(
        find.text('Clear specific reader settings for this device'),
      );
      await _flush(tester, appdata.saveData(false));
      expect(appdata.settings.isDeviceSpecificSettingsEnabled(), isFalse);
      expect(
        appdata
            .settings['deviceSpecificSettings']['other-device']['readerBrightness'],
        90,
      );
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 50);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rapid dimming previews immediately and persists every accepted change without drag end',
    (tester) async {
      final root = _prepare();
      final preview = ReaderBrightnessPreview();
      var callbacks = 0;
      await tester.pumpWidget(
        _host(
          ReaderBrightnessSetting(
            comicId: 'comic',
            sourceKey: 'local',
            preview: preview,
            onChanged: (_) => callbacks++,
          ),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final change = tester
          .widget<ReaderBrightnessControl>(find.byType(ReaderBrightnessControl))
          .onBrightnessChanged;
      change(20);
      change(35);
      change(75);
      await tester.pump();
      expect(preview.brightness, 75);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 75);
      expect(appdata.settings['readerBrightness'], 50);
      expect(callbacks, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(preview.brightness, isNull);
      expect(callbacks, 1);
      final saved = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      );
      expect(saved['settings']['readerBrightness'], 75);
      await tester.pumpWidget(const SizedBox.shrink());
      preview.dispose();
    },
  );

  testWidgets(
    'detached brightness form retains preview and the reader owns its queued assignment',
    (tester) async {
      _prepare();
      final preview = ReaderBrightnessPreview();
      final work = ImageWork();
      await tester.pumpWidget(
        _host(ReaderBrightnessSetting(preview: preview), work: work),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester
          .widget<ReaderBrightnessControl>(find.byType(ReaderBrightnessControl))
          .onBrightnessChanged(25);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(preview.brightness, 25);
      var drained = false;
      final closing = work.dispose().then((_) => drained = true);
      await tester.pump();
      expect(drained, isFalse);
      release.complete();
      await _flush(tester, Future.wait([exclusive, closing]));
      expect(appdata.settings['readerBrightness'], 25);
      expect(preview.brightness, isNull);
      expect(tester.takeException(), isNull);
      preview.dispose();
    },
  );

  testWidgets(
    'repaired brightness failure does not remain in the reader exit report',
    (tester) async {
      final root = _prepare();
      final work = ImageWork();
      await tester.pumpWidget(
        _host(const ReaderBrightnessSetting(), work: work),
      );
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      tester
          .widget<ReaderBrightnessControl>(find.byType(ReaderBrightnessControl))
          .onBrightnessChanged(30);
      for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Retry'), findsOneWidget);
      blocked.deleteSync();
      await tester.tap(find.text('Retry'));
      await _flush(tester, appdata.saveData(false));
      final resume = await work.prepareForExit();
      resume();
      expect(appdata.settings['readerBrightness'], 30);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await work.dispose();
    },
  );

  testWidgets(
    'retargeted form keeps the original assignment and clears only its own preview',
    (tester) async {
      _prepare();
      appdata.settings.setEnabledComicSpecificSettings('one', 'local', true);
      appdata.settings.setEnabledComicSpecificSettings('two', 'local', true);
      var comic = 'one';
      var callbacks = 0;
      late StateSetter updateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, update) {
              updateHost = update;
              return ReaderBrightnessSetting(
                comicId: comic,
                sourceKey: 'local',
                onChanged: (_) => callbacks++,
              );
            },
          ),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester
          .widget<ReaderBrightnessControl>(find.byType(ReaderBrightnessControl))
          .onBrightnessChanged(20);
      updateHost(() => comic = 'two');
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 50);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(
        appdata.settings.getReaderSetting('one', 'local', 'readerBrightness'),
        20,
      );
      expect(
        appdata.settings.getReaderSetting('two', 'local', 'readerBrightness'),
        50,
      );
      expect(callbacks, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'comic scope toggle and reset wait for admission and preserve another comic',
    (tester) async {
      _prepare();
      appdata.settings.setReaderSetting(
        'other',
        'local',
        'readerBrightness',
        80,
      );
      var callbacks = 0;
      await tester.pumpWidget(
        _host(
          ReaderSettings(
            comicId: 'comic',
            comicSource: 'local',
            onChanged: (_) => callbacks++,
          ),
        ),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Customize other settings for this comic',
            ),
          )
          .onChanged!(true);
      expect(
        appdata.settings.isComicSpecificSettingsEnabled('comic', 'local'),
        isFalse,
      );
      expect(callbacks, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(
        appdata.settings.isComicSpecificSettingsEnabled('comic', 'local'),
        isTrue,
      );
      expect(callbacks, 1);
      await tester.tap(find.text('Reset all settings for this comic'));
      await _flush(tester, appdata.saveData(false));
      expect(
        appdata.settings.isComicSpecificSettingsEnabled('comic', 'local'),
        isFalse,
      );
      expect(
        appdata
            .settings['comicSpecificSettings']['other@local']['readerBrightness'],
        80,
      );
      expect(callbacks, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'disabling chapter comments commits both flags in one draft after admission',
    (tester) async {
      final root = _prepare();
      appdata.settings['showChapterComments'] = true;
      appdata.settings['showChapterCommentsAtEnd'] = true;
      await tester.pumpWidget(_host(const ReaderSettings()));
      await tester.scrollUntilVisible(
        find.text('Show Chapter Comments'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      final control = find.ancestor(
        of: find.text('Show Chapter Comments'),
        matching: find.byType(SwitchSetting),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(
        find.descendant(of: control, matching: find.byType(Switch)),
      );
      await tester.pump();
      expect(appdata.settings['showChapterComments'], isTrue);
      expect(appdata.settings['showChapterCommentsAtEnd'], isTrue);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      final saved = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings'];
      expect(saved['showChapterComments'], isFalse);
      expect(saved['showChapterCommentsAtEnd'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
