import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/reader.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  testWidgets('vertical flow modes expose and persist side margins', (
    tester,
  ) async {
    // Appdata owns a shared write queue; keep both modes in one test lifecycle.
    for (final mode in ['continuousTopToBottom', 'waterfallTopToBottom']) {
      tester.view.physicalSize = const Size(360, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
      final directory = Directory.systemTemp.createTempSync('reader-margins-');
      App.dataPath = directory.path;
      appdata.settings['language'] = 'zh-CN';
      appdata.settings['readerMode'] = mode;
      appdata.settings['autoReaderMode'] = false;
      appdata.settings['readerSideMargin'] = 0;
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      await AppTranslation.init();
      addTearDown(() {
        previous.forEach((key, value) => appdata.settings[key] = value);
        directory.deleteSync(recursive: true);
      });
      String? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 720)),
            child: Scaffold(
              body: SizedBox(
                width: 360,
                child: ReaderSettings(onChanged: (key) => changed = key),
              ),
            ),
          ),
        ),
      );
      final setting = find.byWidgetPredicate(
        (widget) =>
            widget is SliderSetting &&
            widget.settingsIndex == 'readerSideMargin',
      );
      await tester.scrollUntilVisible(setting, 400, maxScrolls: 40);
      await tester.pumpAndSettle();
      expect(find.text('左右边距（每侧）'), findsOneWidget);
      final slider = find.descendant(
        of: setting,
        matching: find.byType(Slider),
      );
      await tester.tapAt(tester.getCenter(slider));
      var persistedChange = false;
      final pendingChange = appdata
          .saveData(false)
          .whenComplete(() => persistedChange = true);
      for (var i = 0; i < 500 && !persistedChange; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(persistedChange, isTrue);
      await pendingChange;
      await tester.pumpAndSettle();
      expect(appdata.settings['readerSideMargin'], inInclusiveRange(1, 30));
      expect(changed, 'readerSideMargin');
      expect(tester.takeException(), isNull);
      final marginSetting = tester.widget<SliderSetting>(setting);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(body: marginSetting),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('左右边距（每侧）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      var completed = false;
      final saved = appdata
          .saveData(false)
          .whenComplete(() => completed = true);
      // Let real file I/O and the fake widget clock both advance.
      for (var i = 0; i < 500 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed, isTrue);
      await saved;
      final persisted = jsonDecode(
        File('${directory.path}/appdata.json').readAsStringSync(),
      );
      expect(
        persisted['settings']['readerSideMargin'],
        appdata.settings['readerSideMargin'],
      );
    }
  });
}
