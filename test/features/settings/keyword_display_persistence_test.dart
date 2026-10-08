import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/pop_up_widget.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/settings/keyword_blocking.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

Directory _prepare() {
  final root = Directory.systemTemp.createTempSync('keyword-display-');
  final previousPath = App.dataPath;
  final previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map;
  App.dataPath = root.path;
  appdata.settings['disableSyncFields'] = '';
  appdata.settings['blockedWords'] = <String>['alpha', 'beta'];
  appdata.settings['blockedCommentWords'] = <String>['comment'];
  appdata.settings[FavoritePreferences.displayMode.key] = 'list';
  appdata.settings[FavoritePreferences.galleryColumns.key] = 0;
  registerShowMessageHandler((context, message) {});
  addTearDown(() {
    App.dataPath = previousPath;
    previous.forEach((key, value) => appdata.settings[key] = value);
    root.deleteSync(recursive: true);
  });
  return root;
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

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
  await tester.pump();
}

Map<String, dynamic> _saved(Directory root) =>
    (jsonDecode(File('${root.path}/appdata.json').readAsStringSync())
            as Map)['settings']
        as Map<String, dynamic>;

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
}

void _mockWindow() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (_) async => false,
      );
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null),
  );
}

void main() {
  App.dataPath = Directory.systemTemp.path;
  testWidgets(
    'favorite display save survives removal and holds the window open',
    (tester) async {
      final root = _prepare();
      _mockWindow();
      var showing = true;
      var exits = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return Scaffold(
                body: showing
                    ? const Center(child: FavoriteDisplayButton())
                    : const Text('Removed'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('Favorite display mode'));
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.text('Gallery'));
      update(() => showing = false);
      await tester.pumpAndSettle();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      for (var i = 0; i < 20 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(exits, 1);
      expect(_saved(root)[FavoritePreferences.displayMode.key], 'gallery');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keyword dialog and pending status fit a narrow dark large-text layout',
    (tester) async {
      _prepare();
      tester.view.physicalSize = const Size(375, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const Scaffold(body: KeywordBlockingSettings(comments: true)),
        ),
      );
      expect(tester.takeException(), isNull);
      await _openAdd(tester);
      await tester.enterText(find.byType(TextField), 'large text');
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump();
      final layoutFailure = tester.takeException();
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      await tester.pumpAndSettle();
      expect(layoutFailure, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final comments in [false, true]) {
    final key = comments ? 'blockedCommentWords' : 'blockedWords';
    testWidgets(
      'keyword deletion follows the word after queued reordering: $key',
      (tester) async {
        final root = _prepare();
        appdata.settings[key] = ['alpha', 'beta', 'alpha'];
        await tester.pumpWidget(
          _host(KeywordBlockingSettings(comments: comments)),
        );
        final remove = tester
            .widget<IconButton>(
              find.descendant(
                of: find.widgetWithText(ListTile, 'alpha').first,
                matching: find.byType(IconButton),
              ),
            )
            .onPressed!;
        final release = Completer<void>();
        final exclusive = AppDataOperations.instance.run(() => release.future);
        final earlier = appdata.updateSettings((draft) {
          (draft[key] as List).insert(0, 'earlier');
        });
        remove();
        await tester.pump();
        expect(appdata.settings[key], ['alpha', 'beta', 'alpha']);
        release.complete();
        await _flush(
          tester,
          Future.wait([exclusive, earlier, appdata.saveData(false)]),
        );
        expect(_saved(root)[key], ['earlier', 'beta']);
        expect(
          _saved(root)[comments ? 'blockedWords' : 'blockedCommentWords'],
          comments ? ['alpha', 'beta'] : ['comment'],
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('keyword add checks duplicates and merges queued edits: $key', (
      tester,
    ) async {
      final root = _prepare();
      await tester.pumpWidget(
        _host(KeywordBlockingSettings(comments: comments)),
      );
      await _openAdd(tester);
      await tester.enterText(
        find.byType(TextField),
        comments ? 'comment' : 'alpha',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump();
      expect(find.text('Keyword already exists'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'new keyword');
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      final earlier = appdata.updateSettings((draft) {
        (draft[key] as List).add('concurrent');
      });
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(appdata.settings[key], comments ? ['comment'] : ['alpha', 'beta']);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, earlier, appdata.saveData(false)]),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(_saved(root)[key], [
        ...(comments ? ['comment'] : ['alpha', 'beta']),
        'concurrent',
        'new keyword',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed keyword save retries without appending the word twice', (
    tester,
  ) async {
    final root = _prepare();
    await tester.pumpWidget(_host(const KeywordBlockingSettings()));
    await _openAdd(tester);
    await tester.enterText(find.byType(TextField), 'retained');
    final blocked = Directory('${root.path}/appdata.json')..createSync();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    for (var i = 0; i < 500 && find.text('Retry').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(appdata.settings['blockedWords'], ['alpha', 'beta', 'retained']);
    blocked.deleteSync();
    await tester.tap(find.text('Retry'));
    await _flush(tester, appdata.saveData(false));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(_saved(root)['blockedWords'], ['alpha', 'beta', 'retained']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'keyword popup back waits for deletion and preserves the home route',
    (tester) async {
      _prepare();
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showPopUpWidget(context, const KeywordBlockingSettings()),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, 'alpha'),
          matching: find.byType(IconButton),
        ),
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Keyword blocking'), findsOneWidget);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      await tester.pumpAndSettle();
      expect(find.text('Keyword blocking'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'window owns keyword add after its dialog route is forcibly removed',
    (tester) async {
      final root = _prepare();
      _mockWindow();
      var exits = 0;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) => WindowFrame(child!, onExit: () => exits++),
          home: const Scaffold(body: KeywordBlockingSettings()),
        ),
      );
      await _openAdd(tester);
      await tester.enterText(find.byType(TextField), 'detached');
      final route = ModalRoute.of(tester.element(find.byType(TextField)))!;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      navigator.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
      for (var i = 0; i < 20 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(exits, 1);
      expect(_saved(root)['blockedWords'], ['alpha', 'beta', 'detached']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('favorite display menu saves mode and columns after admission', (
    tester,
  ) async {
    final root = _prepare();
    await tester.pumpWidget(
      _host(const Center(child: FavoriteDisplayButton())),
    );
    await tester.tap(find.byTooltip('Favorite display mode'));
    await tester.pumpAndSettle();
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    await tester.tap(find.text('Gallery'));
    await tester.pump();
    expect(appdata.settings[FavoritePreferences.displayMode.key], 'list');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    release.complete();
    await _flush(tester, Future.wait([exclusive, appdata.saveData(false)]));
    await tester.pumpAndSettle();
    expect(_saved(root)[FavoritePreferences.displayMode.key], 'gallery');
    await tester.tap(find.byTooltip('Favorite display mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 columns'));
    await _flush(tester, appdata.saveData(false));
    await tester.pumpAndSettle();
    expect(_saved(root)[FavoritePreferences.galleryColumns.key], 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'favorite display ignores a menu selection after its owner is removed',
    (tester) async {
      _prepare();
      var showing = true;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return showing
                  ? const Center(child: FavoriteDisplayButton())
                  : const Text('Removed');
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('Favorite display mode'));
      await tester.pumpAndSettle();
      update(() => showing = false);
      await tester.pump();
      await tester.tap(find.text('Gallery'));
      await tester.pumpAndSettle();
      await _flush(tester, appdata.saveData(false));
      expect(appdata.settings[FavoritePreferences.displayMode.key], 'list');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'favorite display reports persistence failure and retries in the same button',
    (tester) async {
      final root = _prepare();
      await tester.pumpWidget(
        _host(const Center(child: FavoriteDisplayButton())),
      );
      final blocked = Directory('${root.path}/appdata.json')..createSync();
      await tester.tap(find.byTooltip('Favorite display mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gallery'));
      for (
        var i = 0;
        i < 500 && find.byTooltip('Retry').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.byTooltip('Retry'), findsOneWidget);
      blocked.deleteSync();
      await tester.tap(find.byTooltip('Retry'));
      await _flush(tester, appdata.saveData(false));
      expect(_saved(root)[FavoritePreferences.displayMode.key], 'gallery');
      expect(find.byTooltip('Retry'), findsNothing);
      expect(find.byTooltip('Favorite display mode'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
