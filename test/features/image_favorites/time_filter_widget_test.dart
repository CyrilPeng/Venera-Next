import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/image_favorites/image_favorites_page.dart';
import 'package:venera_next/features/image_favorites/type.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';

const _timeKey = 'image_favorites_time_filter';

Future<void> _flushWrites(WidgetTester tester) async {
  var complete = false;
  final write = appdata.writeImplicitData().whenComplete(() => complete = true);
  for (var i = 0; i < 500 && !complete; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(complete, isTrue, reason: 'Implicit writes must finish before reload');
  await write;
}

void main() {
  late ImageFavoriteManager imageManager;
  setUpAll(() {
    App.dataPath = Directory.systemTemp.path;
    App.cachePath = Directory.systemTemp.path;
  });

  Future<Directory> prepare(WidgetTester tester, Object? range) async {
    final root = Directory.systemTemp.createTempSync('time-filter-ui-');
    final previousData = App.dataPath;
    final previousCache = App.cachePath;
    final previousImplicit = appdata.implicitData;
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.implicitData = {_timeKey: range};
    final history = HistoryManager.create();
    imageManager = ImageFavoriteManager.create(history: history);
    await history.init();
    addTearDown(() async {
      // The dialog uses the existing appdata write queue. Drain before cleanup.
      await _flushWrites(tester);
      expect(history.hasPendingWrites, isFalse);
      history.close();
      imageManager.dispose();
      history.dispose();
      appdata.implicitData = previousImplicit;
      App.dataPath = previousData;
      App.cachePath = previousCache;
      root.deleteSync(recursive: true);
    });
    return root;
  }

  Future<void> showPage(
    WidgetTester tester, {
    GlobalKey<NavigatorState>? navigator,
    Widget? body,
    double scale = 1,
    bool dark = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: dark,
          ),
          child: child!,
        ),
        home: Scaffold(body: body ?? ImageFavoritesPage(manager: imageManager)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openFilter(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.sort_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('Filter')));
    await tester.pumpAndSettle();
  }

  Finder confirm() => find.widgetWithText(FilledButton, 'Confirm');

  Future<void> chooseCustom(WidgetTester tester) async {
    await tester.tap(find.byType(Select).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Custom'));
    await tester.pumpAndSettle();
  }

  Finder dateButton(String label) => find.descendant(
    of: find.widgetWithText(ListTile, label),
    matching: find.byType(TextButton),
  );

  for (final range in [
    TimeRange.lastWeek,
    TimeRange(
      end: DateTime(2026, 1, 20, 12, 34, 56, 321),
      duration: const Duration(days: 8),
    ),
    const TimeRange(duration: Duration(days: 9)),
  ]) {
    testWidgets('saved filter $range survives disk and page recreation', (
      tester,
    ) async {
      final root = await prepare(tester, range.toString());
      await showPage(tester);
      await openFilter(tester);
      expect(
        tester.widget<Select>(find.byType(Select).first).current,
        range == TimeRange.lastWeek ? 'Last Week' : 'Custom',
      );
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      await _flushWrites(tester);
      await tester.runAsync(() async {
        appdata.implicitData =
            jsonDecode(
                  File('${root.path}/implicitData.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
      });
      expect(TimeRange.fromString(appdata.implicitData[_timeKey]), range);
      await tester.pumpWidget(const SizedBox());
      await showPage(tester);
      await openFilter(tester);
      expect(
        tester.widget<Select>(find.byType(Select).first).current,
        range == TimeRange.lastWeek ? 'Last Week' : 'Custom',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('custom range cannot save until both dates are selected', (
    tester,
  ) async {
    await prepare(tester, TimeRange.all.toString());
    await showPage(tester);
    await openFilter(tester);
    await chooseCustom(tester);
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    await tester.tap(dateButton('Start Time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    await tester.tap(dateButton('End Time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
    await tester.tap(confirm());
    await tester.pumpAndSettle();
    final saved = TimeRange.fromString(appdata.implicitData[_timeKey]);
    expect(saved.end, isNotNull);
    expect(saved.duration, Duration.zero);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing a rolling custom date turns it into a fixed range', (
    tester,
  ) async {
    await prepare(tester, 'null:777600000');
    await showPage(tester);
    await openFilter(tester);
    await tester.tap(dateButton('Start Time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(confirm());
    await tester.pumpAndSettle();
    expect(TimeRange.fromString(appdata.implicitData[_timeKey]).end, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final value in <Object?>[
    '321:604800000',
    123,
    {'bad': 'value'},
  ]) {
    testWidgets('invalid stored filter $value opens as All', (tester) async {
      await prepare(tester, value);
      await showPage(tester);
      await openFilter(tester);
      expect(tester.widget<Select>(find.byType(Select).first).current, 'All');
      expect(appdata.implicitData[_timeKey], value);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final end in [DateTime(1990, 3, 4), DateTime(2200, 5, 6)]) {
    testWidgets('restored date $end opens both pickers safely', (tester) async {
      final range = TimeRange(end: end, duration: const Duration(days: 2));
      await prepare(tester, range.toString());
      await showPage(tester);
      await openFilter(tester);
      for (final label in ['Start Time', 'End Time']) {
        await tester.tap(dateButton(label));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect(TimeRange.fromString(appdata.implicitData[_timeKey]), range);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('date result after filter dialog removal is ignored', (
    tester,
  ) async {
    await prepare(tester, 'null:777600000');
    final navigator = GlobalKey<NavigatorState>();
    await showPage(tester, navigator: navigator);
    await openFilter(tester);
    final route = ModalRoute.of(tester.element(confirm()))!;
    await tester.tap(dateButton('Start Time'));
    await tester.pumpAndSettle();
    navigator.currentState!.removeRoute(route);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(appdata.implicitData[_timeKey], 'null:777600000');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'confirm after underlying page disposal does not update its state',
    (tester) async {
      await prepare(tester, TimeRange.lastWeek.toString());
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await showPage(
        tester,
        body: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => show
              ? ImageFavoritesPage(manager: imageManager)
              : const SizedBox(),
        ),
      );
      await openFilter(tester);
      visible.value = false;
      await tester.pumpAndSettle();
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(375, 667), const Size(667, 375)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('filter remains usable at $size, text $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await prepare(tester, 'null:777600000');
        await showPage(tester, scale: scale, dark: scale > 1);
        await openFilter(tester);
        await tester.ensureVisible(dateButton('Start Time'));
        await tester.tap(dateButton('Start Time'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsNothing);
        await tester.ensureVisible(confirm());
        await tester.tap(confirm());
        await tester.pumpAndSettle();
        expect(appdata.implicitData[_timeKey], 'null:777600000');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
