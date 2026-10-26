import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/settings/local_favorites.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then(
    (_) => done = true,
    onError: (Object e) {
      failure = e;
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
  await tester.pump();
}

void main() {
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;
  late Directory root;
  late LocalFavoritesManager manager;
  late AppdataImportCheckpoint previous;
  late String previousPath, previousCache;
  setUp(() async {
    previousPath = App.dataPath;
    previousCache = App.cachePath;
    previous = appdata.captureImportCheckpoint();
    root = Directory.systemTemp.createTempSync('favorite-preferences-');
    App.dataPath = App.cachePath = root.path;
    _favoritesOwner = null;
    manager = _favoritesForView();
    await manager.init();
    appdata.settings['extension'] = {
      'keep': [1, 'x'],
    };
    registerShowMessageHandler((_, _) {});
  });
  tearDown(() async {
    await manager.closeAndWait();
    _favoritesOwner = null;
    await appdata.restoreImportCheckpoint(previous, persist: false);
    App.dataPath = previousPath;
    App.cachePath = previousCache;
    root.deleteSync(recursive: true);
  });
  Finder field(String title) => find.widgetWithText(ListTile, title);
  Future<void> open(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      _libraryView(
        MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: LocalFavoritesSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const localFirstTitle = 'Show local favorites before network favorites';
  const closeTitle = 'Auto close favorite panel after operation';
  for (final width in [375.0, 812.0]) {
    testWidgets(
      'custom folder choices cannot save to a retargeted field at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final setting = ValueNotifier('quickFavorite');
        addTearDown(setting.dispose);
        appdata.settings['quickFavorite'] = null;
        appdata.settings['readLaterFolder'] = null;
        await tester.pumpWidget(
          _libraryView(
            MaterialApp(
              home: Scaffold(
                body: ValueListenableBuilder<String>(
                  valueListenable: setting,
                  builder: (context, name, _) => SelectSetting(
                    title: 'Folder',
                    settingKey: name,
                    optionTranslation: const {'target': 'Target'},
                    selectorBuilder: (context, value, onChanged) => TextButton(
                      onPressed: onChanged == null
                          ? null
                          : () => onChanged('target'),
                      child: const Text('Choose'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final oldChoice = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Choose'))
            .onPressed!;
        setting.value = 'readLaterFolder';
        await tester.pump();
        oldChoice();
        await _flush(tester, appdata.saveData(false));
        expect(appdata.settings['quickFavorite'], isNull);
        expect(appdata.settings['readLaterFolder'], isNull);
        await tester.tap(find.widgetWithText(TextButton, 'Choose'));
        await _flush(tester, appdata.saveData(false));
        expect(appdata.settings['quickFavorite'], isNull);
        expect(appdata.settings['readLaterFolder'], 'target');
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'actual favorite form reads malformed flags and choices without rewriting them',
    (tester) async {
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      appdata.settings['localFavoritesFirst'] = 'false';
      appdata.settings['autoCloseFavoritePanel'] = 1;
      appdata.settings['newFavoriteAddTo'] = 'invalid';
      appdata.settings['moveFavoriteAfterRead'] = false;
      appdata.settings['quickFavorite'] = 12;
      appdata.settings['onClickFavorite'] = 'invalid';
      final before = jsonEncode(appdata.toJson());
      await open(tester);
      expect(
        tester
            .widget<Switch>(
              find.descendant(
                of: field(localFirstTitle),
                matching: find.byType(Switch),
              ),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<Switch>(
              find.descendant(
                of: field(closeTitle),
                matching: find.byType(Switch),
              ),
            )
            .value,
        isFalse,
      );
      for (final (title, expected) in [
        ('Add new favorite to', 'End'),
        ('Move favorite after reading', 'None'),
        ('Quick Favorite', 'None'),
        ('Click favorite', 'View Detail'),
      ]) {
        final item = find.widgetWithText(SelectSetting, title);
        await tester.scrollUntilVisible(
          item,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.descendant(of: item, matching: find.text(expected)),
          findsOneWidget,
        );
      }
      expect(jsonEncode(appdata.toJson()), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'favorite flag waits for admission and saves only its captured field',
    (tester) async {
      appdata.settings['localFavoritesFirst'] = true;
      appdata.settings['autoCloseFavoritePanel'] = 'legacy invalid';
      await open(tester);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final change = tester
          .widget<Switch>(
            find.descendant(
              of: field(localFirstTitle),
              matching: find.byType(Switch),
            ),
          )
          .onChanged!;
      change(false);
      await tester.pump();
      final before = appdata.settings['localFavoritesFirst'];
      await tester.pumpWidget(const SizedBox.shrink());
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      expect(before, isTrue);
      final data = jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings'];
      expect(data['localFavoritesFirst'], isFalse);
      expect(data['autoCloseFavoritePanel'], 'legacy invalid');
      expect(data['extension'], {
        'keep': [1, 'x'],
      });
      appdata.settings['localFavoritesFirst'] = true;
      await _flush(tester, appdata.loadDataForTesting(root.path));
      expect(appdata.settings['localFavoritesFirst'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  for (final scenario in [
    (size: const Size(375, 740), dark: true, scale: 2.0),
    (size: const Size(812, 600), dark: false, scale: 1.0),
  ]) {
    testWidgets('favorite choice keeps options and queued save at $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      appdata.settings['newFavoriteAddTo'] = 'broken';
      await open(tester, dark: scenario.dark, scale: scenario.scale);
      final tile = field('Add new favorite to');
      await tester.scrollUntilVisible(
        tile,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      final selector = find.descendant(of: tile, matching: find.byType(Select));
      await tester.tap(selector.evaluate().isEmpty ? tile : selector);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(PopupMenuItem<String>, 'Start'),
        findsOneWidget,
      );
      expect(find.widgetWithText(PopupMenuItem<String>, 'End'), findsOneWidget);
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Start'));
      await tester.pump();
      final before = appdata.settings['newFavoriteAddTo'];
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      await tester.pumpAndSettle();
      expect(before, 'broken');
      expect(appdata.settings['newFavoriteAddTo'], 'start');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
Widget _libraryView(Widget child) {
  return FavoritesScope(manager: _favoritesForView(), child: child);
}
