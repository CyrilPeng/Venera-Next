import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

List<String> _pageOrder(WidgetTester tester) {
  final builder = tester.widget<ReorderableBuilder<String>>(
    find.byType(ReorderableBuilder<String>),
  );
  return builder.children!
      .map((child) => (child.key! as ValueKey<String>).value)
      .toList();
}

void _setUpPages(String settingKey, int count) {
  final directory = Directory.systemTemp.createTempSync('venera-page-order-');
  final previous = appdata.settings[settingKey];
  App.dataPath = directory.path;
  appdata.settings[settingKey] = [
    '',
    for (var i = 0; i < count; i++) 'page-$i',
  ];
  addTearDown(() {
    appdata.settings[settingKey] = previous;
    directory.deleteSync(recursive: true);
  });
}

Future<TestGesture> _holdPage(
  WidgetTester tester,
  String key,
  PointerDeviceKind kind,
) async {
  final builder = tester.widget<ReorderableBuilder<String>>(
    find.byType(ReorderableBuilder<String>),
  );
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(ValueKey(key))),
    kind: kind,
  );
  await tester.pump(builder.longPressDelay + const Duration(milliseconds: 50));
  return gesture;
}

Future<void> _dragPage(
  WidgetTester tester,
  String from,
  String to,
  PointerDeviceKind kind,
) async {
  final target = tester.getCenter(find.byKey(ValueKey(to)));
  final gesture = await _holdPage(tester, from, kind);
  await gesture.moveTo(target);
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _reloadPages(
  WidgetTester tester,
  String settingKey,
  Widget Function() buildPages,
  List<String> expected,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _flushSettings(tester);
  await tester.runAsync(() async {
    appdata.settings[settingKey] = <String>[];
    await appdata.loadDataForTesting(App.dataPath);
  });
  expect(appdata.settings[settingKey], expected);
  await tester.pumpWidget(MaterialApp(home: buildPages()));
  await tester.pumpAndSettle();
  expect(_pageOrder(tester), expected);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _flushSettings(tester);
}

Future<void> _flushSettings(WidgetTester tester) async {
  var completed = false;
  final saved = appdata.saveData(false).whenComplete(() => completed = true);
  // File I/O uses real time; its widget callbacks still need the test clock.
  for (var i = 0; i < 500 && !completed; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    completed,
    isTrue,
    reason: 'Settings writes must finish before reload',
  );
  await saved;
}

void main() {
  testWidgets(
    'page selectors persist drag order across input and layout changes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Appdata owns a shared write queue, so exercise selectors in one lifecycle.
      for (final (settingKey, buildPages) in [
        ('explore_pages', setExplorePagesWidget),
        ('categories', setCategoryPagesWidget),
        ('favorites', setFavoritesPagesWidget),
        ('searchSources', setSearchSourcesWidget),
      ]) {
        for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
          _setUpPages(settingKey, 4);

          await tester.pumpWidget(MaterialApp(home: buildPages()));
          await tester.pumpAndSettle();
          expect(_pageOrder(tester), ['page-0', 'page-1', 'page-2', 'page-3']);

          await _dragPage(tester, 'page-0', 'page-2', kind);
          const expected = ['page-1', 'page-2', 'page-0', 'page-3'];
          expect(
            _pageOrder(tester),
            expected,
            reason: '$settingKey ${kind.name}',
          );
          await _reloadPages(tester, settingKey, buildPages, expected);
        }
      }

      _setUpPages('explore_pages', 30);
      tester.view.physicalSize = const Size(480, 600);

      await tester.pumpWidget(MaterialApp(home: setExplorePagesWidget()));
      await tester.pumpAndSettle();
      final builder = tester.widget<ReorderableBuilder<String>>(
        find.byType(ReorderableBuilder<String>),
      );
      final controller = builder.scrollController!;
      final grid = tester.getRect(find.byType(GridView));
      final gesture = await _holdPage(
        tester,
        'page-3',
        PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(grid.center.dx, grid.bottom - 10));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(controller.offset, greaterThan(0));
      await gesture.up();
      await tester.pumpAndSettle();
      final beforeResize = _pageOrder(tester);
      expect(beforeResize, hasLength(30));
      expect(beforeResize.toSet(), {for (var i = 0; i < 30; i++) 'page-$i'});
      expect(beforeResize.indexOf('page-3'), greaterThan(3));

      tester.view.physicalSize = const Size(820, 500);
      await tester.pumpAndSettle();
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_pageOrder(tester), beforeResize);
      await _dragPage(
        tester,
        beforeResize[0],
        beforeResize[2],
        PointerDeviceKind.touch,
      );
      final expected = List<String>.from(beforeResize);
      expected.insert(2, expected.removeAt(0));
      expect(_pageOrder(tester), expected);
      await _reloadPages(
        tester,
        'explore_pages',
        setExplorePagesWidget,
        expected,
      );
    },
  );
}
