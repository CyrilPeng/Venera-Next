import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/history_model.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/features/settings/about.dart';
import 'package:venera_next/features/settings/app.dart';
import 'package:venera_next/features/settings/app_controls.dart';
import 'package:venera_next/features/settings/setting_components.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_work.dart';

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then<void>(
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
  await tester.pump();
}

void main() {
  App.dataPath = App.cachePath = Directory.systemTemp.path;
  late Directory root;
  late HistoryManager manager;
  late HistoryManager? previousManager;
  late AppdataImportCheckpoint checkpoint;
  late String previousPath, previousCache;
  setUp(() async {
    checkpoint = appdata.captureImportCheckpoint();
    previousPath = App.dataPath;
    previousCache = App.cachePath;
    root = Directory.systemTemp.createTempSync('application-behavior-');
    App.dataPath = App.cachePath = root.path;
    previousManager = _historyOwner;
    appdata.settings['historyRetentionDays'] = 0;
    appdata.settings['language'] = 'en-US';
    manager = HistoryManager.create();
    _historyOwner = manager;
    await manager.init();
    await manager.addHistory(
      History.fromMap({
        'id': 'old',
        'type': ComicType.local.value,
        'time': DateTime(2000).millisecondsSinceEpoch,
        'title': 'old',
        'subtitle': '',
        'cover': '',
        'ep': 1,
        'page': 1,
        'readEpisode': ['1'],
        'max_page': 1,
      }),
    );
    registerShowMessageHandler((_, _) {});
  });
  tearDown(() async {
    // Each widget test drains accepted saves while its fake clock is active.
    // Re-awaiting that completed queue from real-time teardown retains its zone.
    expect(manager.hasPendingWrites, isFalse);
    manager.close();
    _historyOwner = previousManager;
    await CacheManager.instance?.dispose();
    await appdata.restoreImportCheckpoint(checkpoint, persist: false);
    App.dataPath = previousPath;
    App.cachePath = previousCache;
    root.deleteSync(recursive: true);
  });
  tearDownAll(() => LocalManager().dispose());
  Future<void> open(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
    bool dark = false,
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
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SettingsSaveState owner(WidgetTester tester) =>
      tester.state<SettingsSaveState>(find.byType(HistoryRetentionSetting));

  testWidgets(
    'retention form reads malformed and long values without editing or deleting',
    (tester) async {
      for (final value in <Object?>['bad', null, double.infinity, 365]) {
        appdata.settings['historyRetentionDays'] = value;
        await open(tester, const HistoryRetentionSetting());
        expect(
          tester.widget<Slider>(find.byType(Slider)).value,
          value == 365 ? 182 : 0,
        );
        expect(appdata.settings['historyRetentionDays'], same(value));
        expect(manager.find('old', ComicType.local), isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'drag preview makes no edit and accepted cleanup survives removal in original reader work',
    (tester) async {
      final work = ImageWork();
      await open(
        tester,
        SettingsSaveScope(work: work, child: const HistoryRetentionSetting()),
      );
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(14);
      slider.onChanged!(7);
      await tester.pump();
      expect(appdata.settings['historyRetentionDays'], 0);
      expect(File('${root.path}/appdata.json').existsSync(), isFalse);
      slider.onChangeEnd!(7);
      await tester.pump();
      final retained = owner(tester);
      var prepared = false;
      final preparing = work.prepareForExit().then((resume) {
        prepared = true;
        resume();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      expect(prepared, isFalse);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, retained.waitForSettingsSave(), preparing]),
      );
      expect(prepared, isTrue);
      expect(manager.find('old', ComicType.local), isNull);
      expect(
        jsonDecode(
          File('${root.path}/appdata.json').readAsStringSync(),
        )['settings']['historyRetentionDays'],
        7,
      );
      await work.dispose();
    },
  );

  testWidgets(
    'retention cleanup failure stays visible and retry repairs the selected choice',
    (tester) async {
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      manager.imageFavoritesDatabase.execute(
        "CREATE TRIGGER deny_retention BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'retention denied'); END;",
      );
      await open(tester, const HistoryRetentionSetting(), dark: true, scale: 2);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(14);
      slider.onChangeEnd!(14);
      for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      expect(appdata.settings['historyRetentionDays'], 14);
      expect(manager.find('old', ComicType.local), isNotNull);
      manager.imageFavoritesDatabase.execute('DROP TRIGGER deny_retention');
      await tester.tap(find.text('Retry'));
      await _flush(tester, owner(tester).waitForSettingsSave());
      expect(find.text('Retry'), findsNothing);
      expect(manager.find('old', ComicType.local), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scenario in [
    (size: const Size(375, 740), dark: true, scale: 2.0),
    (size: const Size(812, 600), dark: false, scale: 1.0),
  ]) {
    testWidgets(
      'real language form keeps old choices and queues only selected field at $scenario',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        LocalManager().path = root.path;
        appdata.settings['language'] = 'unknown';
        appdata.settings['checkUpdateOnStart'] = 'unrelated-invalid';
        await open(
          tester,
          const AppSettings(),
          dark: scenario.dark,
          scale: scenario.scale,
        );
        final field = find.widgetWithText(SelectSetting, 'Language');
        await tester.scrollUntilVisible(
          field,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        expect(appdata.settings['language'], 'unknown');
        final tile = find.descendant(
          of: field,
          matching: find.byType(ListTile),
        );
        final select = find.descendant(of: tile, matching: find.byType(Select));
        await tester.tap(select.evaluate().isEmpty ? tile : select);
        await tester.pumpAndSettle();
        for (final label in ['System', '简体中文', '繁體中文', 'English']) {
          expect(
            find.widgetWithText(PopupMenuItem<String>, label),
            findsOneWidget,
          );
        }
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'English'));
        await tester.pump();
        final before = appdata.settings['language'];
        release.complete();
        await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
        expect(before, 'unknown');
        expect(appdata.settings['language'], 'en-US');
        expect(appdata.settings['checkUpdateOnStart'], 'unrelated-invalid');
        await _flush(tester, appdata.loadDataForTesting(root.path));
        expect(appdata.settings['language'], 'en-US');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await _flush(tester, CacheManager.instance!.dispose());
      },
    );
  }

  testWidgets('about startup toggle repairs only its invalid stored flag', (
    tester,
  ) async {
    appdata.settings['checkUpdateOnStart'] = 'true';
    await open(tester, const AboutSettings());
    final field = find.widgetWithText(
      SwitchSetting,
      'Check for updates on startup',
    );
    await tester.scrollUntilVisible(
      field,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final toggle = find.descendant(of: field, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(appdata.settings['checkUpdateOnStart'], 'true');
    tester.widget<Switch>(toggle).onChanged!(true);
    await _flush(tester, appdata.saveData(false));
    expect(
      jsonDecode(
        File('${root.path}/appdata.json').readAsStringSync(),
      )['settings']['checkUpdateOnStart'],
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  return HistoryScope(manager: _historyForView(), child: child);
}
