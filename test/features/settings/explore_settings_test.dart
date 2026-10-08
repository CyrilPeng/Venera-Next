import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/settings/explore_settings.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('explore-settings-');
  App.dataPath = root.path;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
  addTearDown(() {
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
  expect(finished, isTrue, reason: 'The real settings write must finish');
  expect(failure, isNull);
  await operation;
  await tester.pumpAndSettle();
}

Widget _host({Brightness brightness = Brightness.light, double scale = 1}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: const OverlayWidget(Scaffold(body: ExploreSettings())),
    );

Future<Finder> _show(WidgetTester tester, String title) async {
  final field = find.ancestor(
    of: find.text(title),
    matching: find.byType(ListTile),
  );
  // Advance the lazy slivers without dragging through an editable slider.
  for (var i = 0; i < 40 && field.evaluate().isEmpty; i++) {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo((position.pixels + 180).clamp(0, position.maxScrollExtent));
    await tester.pump();
  }
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  return field;
}

Map _saved(Directory root) =>
    jsonDecode(File('${root.path}/appdata.json').readAsStringSync())['settings']
        as Map;

void main() {
  for (final (size, brightness, scale) in [
    (const Size(375, 812), Brightness.dark, 2.0),
    (const Size(812, 375), Brightness.light, 1.0),
  ]) {
    testWidgets('invalid stored display values render safely at $size', (
      tester,
    ) async {
      final root = _prepare();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final raw = <String, Object?>{
        'comicDisplayMode': ['bad'],
        'comicTileScale': 'bad',
        'showFavoriteStatusOnTile': null,
        'showHistoryStatusOnTile': 1,
        'showUpdateStatusOnTile': 'false',
        'reverseChapterOrder': 'bad',
        'autoAddLanguageFilter': {},
        'initialPage': '-1',
        'comicListDisplayMode': 'continuous',
      };
      raw.forEach((key, value) => appdata.settings[key] = value);
      final before = jsonEncode(appdata.toJson()['settings']);
      await tester.pumpWidget(_host(brightness: brightness, scale: scale));
      final mode = await _show(tester, 'Display mode of comic tile');
      expect(
        find.descendant(of: mode, matching: find.text('Detailed')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byType(Slider));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
      for (final (title, value) in [
        ('Show favorite status on comic tile', true),
        ('Show history on comic tile', false),
        ('Show update status on comic tile', true),
        ('Reverse default chapter order', false),
      ]) {
        final field = await _show(tester, title);
        expect(
          tester
              .widget<Switch>(
                find.descendant(of: field, matching: find.byType(Switch)),
              )
              .value,
          value,
        );
      }
      final language = await _show(tester, 'Auto Language Filters');
      expect(
        find.descendant(of: language, matching: find.text('None')),
        findsOneWidget,
      );
      final initial = await _show(tester, 'Initial Page');
      expect(
        find.descendant(of: initial, matching: find.text('Home Page')),
        findsOneWidget,
      );
      final list = await _show(tester, 'Display mode of comic list');
      expect(
        find.descendant(of: list, matching: find.text('Continuous')),
        findsOneWidget,
      );
      expect(jsonEncode(appdata.toJson()['settings']), before);
      expect(File('${root.path}/appdata.json').existsSync(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [375.0, 812.0]) {
    testWidgets(
      'display selections save legacy strings and retain other fields at $width',
      (tester) async {
        final root = _prepare();
        tester.view.physicalSize = Size(width, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appdata.settings['initialPage'] = 99;
        appdata.settings['comicListDisplayMode'] = 'continuous';
        appdata.settings['disableSyncFields'] = 'initialPage';
        appdata.settings['explore_pages'] = ['retired', 'known', 'retired'];
        appdata.settings['deviceSpecificSettings'] = {
          'future': {'value': 9},
        };
        final before =
            jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
        await tester.pumpWidget(_host());
        final initial = await _show(tester, 'Initial Page');
        await tester.tap(
          find.descendant(
            of: initial,
            matching: find.byIcon(Icons.arrow_drop_down),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Explore Page').last);
        await tester.pump();
        await _flush(tester, appdata.saveData(false));
        expect(_saved(root)['initialPage'], '2');
        expect(_saved(root)['comicListDisplayMode'], 'continuous');
        final list = await _show(tester, 'Display mode of comic list');
        await tester.tap(
          find.descendant(
            of: list,
            matching: find.byIcon(Icons.arrow_drop_down),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continuous').last);
        await tester.pump();
        await _flush(tester, appdata.saveData(false));
        final saved = _saved(root);
        expect(saved['initialPage'], '2');
        expect(saved['comicListDisplayMode'], 'Continuous');
        for (final entry in before.entries) {
          if (!['initialPage', 'comicListDisplayMode'].contains(entry.key)) {
            expect(saved[entry.key], entry.value, reason: entry.key as String);
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_host());
        final rebuilt = await _show(tester, 'Initial Page');
        expect(
          find.descendant(of: rebuilt, matching: find.text('Explore Page')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'real discovery slider and switch wait for admission before saving',
    (tester) async {
      final root = _prepare();
      appdata.settings['comicTileScale'] = 1.0;
      appdata.settings['showFavoriteStatusOnTile'] = true;
      await tester.pumpWidget(_host());
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      tester.widget<Slider>(find.byType(Slider)).onChanged!(1.25);
      final field = find.ancestor(
        of: find.text('Show favorite status on comic tile'),
        matching: find.byType(SwitchSetting),
      );
      await tester.ensureVisible(field);
      await tester.pump();
      tester
          .widget<Switch>(
            find.descendant(of: field, matching: find.byType(Switch)),
          )
          .onChanged!(false);
      await tester.pump();
      expect(appdata.settings['comicTileScale'], 1.0);
      expect(appdata.settings['showFavoriteStatusOnTile'], isTrue);
      expect(File('${root.path}/appdata.json').existsSync(), isFalse);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(_saved(root)['comicTileScale'], 1.25);
      expect(_saved(root)['showFavoriteStatusOnTile'], isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
