import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/favorites/side_bar.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:window_manager/window_manager.dart';

Future<void> _flush(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? error;
  operation.then(
    (_) => done = true,
    onError: (Object e) {
      error = e;
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
  expect(error, isNull);
  await tester.pump();
}

Future<Directory> _prepare(WidgetTester tester) async {
  final root = Directory.systemTemp.createTempSync('favorites-view-');
  final previousPath = App.dataPath;
  final previousSettings = Map<String, dynamic>.from(
    appdata.toJson()['settings'] as Map,
  );
  final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
  App.dataPath = root.path;
  App.cachePath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings['disableSyncFields'] = '';
  appdata.implicitData = {
    'local_favorites_read_filter': 'All',
    'unrelated': 42,
  };
  LocalFavoritesManager.cache = null;
  HistoryManager.cache = null;
  final manager = LocalFavoritesManager();
  final history = HistoryManager();
  await tester.runAsync(() async {
    await manager.init();
    await history.init();
    await manager.createFolder('A');
    await manager.createFolder('B');
    await manager.linkFolderToNetwork('A', 'test-source', 'remote-A');
  });
  registerShowMessageHandler((_, _) {});
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await appdata.writeImplicitData();
      await manager.closeAndWait();
      history.close();
    });
    LocalFavoritesManager.cache = null;
    HistoryManager.cache = null;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    appdata.implicitData = previousImplicit;
    App.dataPath = previousPath;
    root.deleteSync(recursive: true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });
  return root;
}

Map _saved(Directory root) =>
    jsonDecode(File('${root.path}/implicitData.json').readAsStringSync())
        as Map;

Widget _local({
  String folder = 'A',
  Future<void> Function(String, int, String, String)? importFolder,
}) => LocalFavoritesPage(
  folder: folder,
  showFolders: () {},
  onFolderSelected: (_, _) {},
  updateFolderList: () {},
  importFolder: importFolder ?? (_, _, _, _) async {},
);

Widget _host(Widget child, {Future<void> Function()? onExit}) => MaterialApp(
  navigatorKey: appNavigation.rootNavigatorKey,
  builder: onExit == null
      ? null
      : (_, child) => WindowFrame(child!, onExit: onExit),
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;

  testWidgets(
    'folder selection previews latest folder and detached window waits for saves',
    (tester) async {
      final root = await _prepare(tester);
      var showing = true;
      var exits = 0;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return showing ? const FavoritesPage() : const SizedBox();
            },
          ),
          onExit: () async => exits++,
        ),
      );
      final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
      final select = tester
          .widget<FavoritesFolderSidebar>(find.byType(FavoritesFolderSidebar))
          .onFolderSelected;
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      select(false, 'A');
      select(false, 'B');
      await tester.pump();
      expect(
        tester
            .widget<LocalFavoritesPage>(find.byType(LocalFavoritesPage))
            .folder,
        'B',
      );
      expect(appdata.implicitData['favoriteFolder'], isNull);
      update(() => showing = false);
      await tester.pump();
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(exits, 0);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      for (var i = 0; i < 20 && exits == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(exits, 1);
      expect(_saved(root)['favoriteFolder'], {'name': 'B', 'isNetwork': false});
      expect(_saved(root)['unrelated'], 42);
    },
  );

  testWidgets(
    'filter persists after parent removal without updating retired page',
    (tester) async {
      final root = await _prepare(tester);
      var showing = true;
      late StateSetter update;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return showing ? _local() : const SizedBox();
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('Filter'));
      await tester.pumpAndSettle();
      tester.widget<Select>(find.byType(Select)).onTap!(2);
      await tester.pump();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      update(() => showing = false);
      await tester.pump();
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, appdata.writeImplicitData()]),
      );
      await tester.pumpAndSettle();
      expect(_saved(root)['local_favorites_read_filter'], 'Completed');
      expect(find.text('Confirm'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sync waits for saved pages and retains selection across resize',
    (tester) async {
      final root = await _prepare(tester);
      final calls = <(String, int, String, String)>[];
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          _local(
            importFolder: (source, pages, folder, remote) async {
              calls.add((source, pages, folder, remote));
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('Sync'));
      await tester.pumpAndSettle();
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      tester.widget<Select>(find.byType(Select)).onTap!(3);
      await tester.pump();
      tester.view.physicalSize = const Size(375, 800);
      await tester.pump();
      expect(tester.widget<Select>(find.byType(Select)).current, '5');
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, appdata.writeImplicitData()]),
      );
      await tester.pumpAndSettle();
      expect(calls, [('test-source', 5, 'A', 'remote-A')]);
      expect(_saved(root)['local_favorites_update_page_num'], 5);
    },
  );

  testWidgets('retiring sync parent saves pages but never imports old folder', (
    tester,
  ) async {
    final root = await _prepare(tester);
    var calls = 0;
    var showing = true;
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (_, setState) {
            update = setState;
            return showing
                ? _local(
                    importFolder: (_, _, _, _) async {
                      calls++;
                    },
                  )
                : const SizedBox();
          },
        ),
      ),
    );
    await tester.tap(find.byTooltip('Sync'));
    await tester.pumpAndSettle();
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    tester.widget<Select>(find.byType(Select)).onTap!(0);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    update(() => showing = false);
    await tester.pump();
    await tester.pump();
    expect(find.text('Update'), findsNothing);
    release.complete();
    await _flush(tester, Future.wait([exclusive, appdata.writeImplicitData()]));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(_saved(root)['local_favorites_update_page_num'], 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sync outside dismissal waits for saving in narrow large text', (
    tester,
  ) async {
    final root = await _prepare(tester);
    tester.view.physicalSize = const Size(375, 800);
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
        home: Scaffold(body: _local()),
      ),
    );
    await tester.tap(find.byTooltip('Sync'));
    await tester.pumpAndSettle();
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    tester.widget<Select>(find.byType(Select)).onTap!(1);
    await tester.pump();
    await tester.tapAt(const Offset(5, 760));
    await tester.pump();
    expect(find.byType(Select), findsOneWidget);
    final layoutError = tester.takeException();
    release.complete();
    await _flush(tester, Future.wait([exclusive, appdata.writeImplicitData()]));
    await tester.pumpAndSettle();
    expect(find.byType(Select), findsNothing);
    expect(_saved(root)['local_favorites_update_page_num'], 2);
    expect(layoutError, isNull);
  });
}
