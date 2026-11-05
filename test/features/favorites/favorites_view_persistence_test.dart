import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/select.dart';
import 'package:venera_next/components/navigation_bar.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_constants.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/favorites/side_bar.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
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
  final previousCachePath = App.cachePath;
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
  _favoritesOwner = null;
  _historyOwner = null;
  final manager = _favoritesForView();
  final history = _historyForView();
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
    _favoritesOwner = null;
    _historyOwner = null;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    appdata.implicitData = previousImplicit;
    App.dataPath = previousPath;
    App.cachePath = previousCachePath;
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
  Future<void> Function(BuildContext, String, int, String, String)?
  importFolder,
}) => LocalFavoritesPage(
  folder: folder,
  showFolders: () {},
  onFolderSelected: (_, _) {},
  updateFolderList: () {},
  importFolder: importFolder ?? (_, _, _, _, _) async {},
);

Widget _host(Widget child, {Future<void> Function()? onExit}) => _libraryView(
  MaterialApp(
    navigatorKey: appNavigation.rootNavigatorKey,
    builder: onExit == null
        ? null
        : (_, child) => WindowFrame(child!, onExit: onExit),
    home: Scaffold(body: child),
  ),
);

Future<void> _saveFolderSelection(WidgetTester tester, String folder) async {
  tester
      .widget<FavoritesFolderSidebar>(find.byType(FavoritesFolderSidebar))
      .onFolderSelected(false, folder);
  await tester.pump();
  final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
  await _flush(tester, owner.waitForSettingsSave());
}

Future<void> _reopenSavedView(WidgetTester tester, Directory root) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.runAsync(() async {
    final manager = _favoritesForView();
    await manager.closeAndWait();
    await manager.init();
  });
  appdata.implicitData = Map<String, dynamic>.from(_saved(root));
  await tester.pumpWidget(_host(const FavoritesPage()));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;

  for (final size in [const Size(375, 800), const Size(1024, 600)]) {
    testWidgets(
      'nested app back returns to the real parent and persists at width ${size.width}',
      (tester) async {
        final root = await _prepare(tester);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previousNavigator = appNavigation.mainNavigatorKey;
        addTearDown(() => appNavigation.mainNavigatorKey = previousNavigator);
        final manager = _favoritesForView();
        await tester.runAsync(() async {
          await manager.createFolder('Parent / collection');
          await manager.createChildFolder(
            'Child / collection',
            manager.folderTree.named('Parent / collection')!.id,
          );
          await manager.addComic(
            'Child / collection',
            FavoriteItem(
              id: 'navigation-comic',
              name: 'Navigation comic',
              coverPath: '',
              author: '',
              type: ComicType.local,
              tags: const [],
            ),
          );
        });
        final child = manager.folderTree.named('Child / collection')!;
        await tester.pumpWidget(_nestedHost(const FavoritesPage()));
        await _saveFolderSelection(tester, child.name);
        await tester.pumpAndSettle();

        expect(
          await appNavigation.rootNavigatorKey.currentState!.maybePop(),
          isTrue,
        );
        await tester.pump();
        final owner = tester.state<SettingsSaveState>(
          find.byType(FavoritesPage),
        );
        await _flush(tester, owner.waitForSettingsSave());
        await tester.pumpAndSettle();
        expect(_visibleFolder(tester), 'Parent / collection');
        expect(_saved(root)['favoriteFolder'], {
          'name': 'Parent / collection',
          'isNetwork': false,
        });
        expect(manager.folderTree.named(child.name)!.id, child.id);
        expect(
          manager.getFolderComics(child.name).single.id,
          'navigation-comic',
        );
        expect(manager.getFolderComics('Parent / collection'), isEmpty);
        expect(
          await appNavigation.rootNavigatorKey.currentState!.maybePop(),
          isFalse,
        );

        await _reopenSavedView(tester, root);
        expect(_visibleFolder(tester), 'Parent / collection');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'folder picker back closes the overlay before returning to parent',
    (tester) async {
      await _prepare(tester);
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _createChildForNavigation(tester);
      await tester.pumpWidget(_host(const FavoritesPage()));
      await _saveFolderSelection(tester, 'Child');
      tester
          .widget<LocalFavoritesPage>(find.byType(LocalFavoritesPage))
          .showFolders();
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesFolderSidebar), findsNWidgets(2));
      await appNavigation.rootNavigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesFolderSidebar), findsOneWidget);
      expect(_visibleFolder(tester), 'Child');
      await appNavigation.rootNavigatorKey.currentState!.maybePop();
      await tester.pump();
      final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
      await _flush(tester, owner.waitForSettingsSave());
      expect(_visibleFolder(tester), 'B');
    },
  );

  testWidgets('back exits search before navigating out of a child', (
    tester,
  ) async {
    await _prepare(tester);
    await _createChildForNavigation(tester);
    await tester.pumpWidget(_host(const FavoritesPage()));
    await _saveFolderSelection(tester, 'Child');
    await tester.tap(
      find.descendant(
        of: find.byType(LocalFavoritesPage),
        matching: find.byIcon(Icons.search),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('favorite-path-parent')), findsNothing);
    await appNavigation.rootNavigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(_visibleFolder(tester), 'Child');
    expect(find.byKey(const ValueKey('favorite-path-parent')), findsOneWidget);
    await appNavigation.rootNavigatorKey.currentState!.maybePop();
    await tester.pump();
    final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
    await _flush(tester, owner.waitForSettingsSave());
    expect(_visibleFolder(tester), 'B');
  });

  testWidgets('back clears multi-selection before navigating out of a child', (
    tester,
  ) async {
    await _prepare(tester);
    await _createChildForNavigation(tester);
    await tester.runAsync(
      () => _favoritesForView().addComic(
        'Child',
        FavoriteItem(
          id: 'selection-comic',
          name: 'Selection comic',
          coverPath: '',
          author: '',
          type: ComicType.local,
          tags: const [],
        ),
      ),
    );
    await tester.pumpWidget(_host(const FavoritesPage()));
    await _saveFolderSelection(tester, 'Child');
    await tester.longPress(find.text('Selection comic').last);
    await tester.pumpAndSettle();
    expect(find.text('Selected 1 comics'), findsOneWidget);
    await appNavigation.rootNavigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Selected 1 comics'), findsNothing);
    expect(_visibleFolder(tester), 'Child');
    await appNavigation.rootNavigatorKey.currentState!.maybePop();
    await tester.pump();
    final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
    await _flush(tester, owner.waitForSettingsSave());
    expect(_visibleFolder(tester), 'B');
  });

  testWidgets(
    'retired parent button cannot follow a child moved to another parent',
    (tester) async {
      await _prepare(tester);
      await _createChildForNavigation(tester);
      await tester.pumpWidget(_host(const FavoritesPage()));
      await _saveFolderSelection(tester, 'Child');
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('favorite-path-parent')),
      );
      await tester.runAsync(
        () => _favoritesForView().moveFolder(
          'Child',
          _favoritesForView().folderTree.named('A')!.id,
        ),
      );
      await tester.pumpAndSettle();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(_visibleFolder(tester), 'Child');
      await tester.tap(find.byKey(const ValueKey('favorite-path-parent')));
      await tester.pump();
      final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
      await _flush(tester, owner.waitForSettingsSave());
      expect(_visibleFolder(tester), 'A');
    },
  );

  testWidgets(
    'parent path button follows a renamed parent by its stable identity',
    (tester) async {
      final root = await _prepare(tester);
      await _createChildForNavigation(tester);
      await tester.pumpWidget(_host(const FavoritesPage()));
      await _saveFolderSelection(tester, 'Child');
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('favorite-path-parent')),
      );
      await tester.runAsync(
        () => _favoritesForView().rename('B', 'Renamed parent'),
      );
      await tester.pumpAndSettle();
      button.onPressed!();
      await tester.pump();
      final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
      await _flush(tester, owner.waitForSettingsSave());
      expect(_visibleFolder(tester), 'Renamed parent');
      expect(_saved(root)['favoriteFolder']['name'], 'Renamed parent');
    },
  );

  testWidgets('back during a pending folder save finishes at the parent', (
    tester,
  ) async {
    final root = await _prepare(tester);
    await _createChildForNavigation(tester);
    await tester.pumpWidget(_host(const FavoritesPage()));
    final release = Completer<void>();
    final exclusive = AppDataOperations.instance.run(() => release.future);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    tester
        .widget<FavoritesFolderSidebar>(find.byType(FavoritesFolderSidebar))
        .onFolderSelected(false, 'Child');
    await tester.pump();
    final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
    expect(owner.savingSettings, isTrue);
    await appNavigation.rootNavigatorKey.currentState!.maybePop();
    await tester.pump();
    release.complete();
    await _flush(tester, Future.wait([exclusive, owner.waitForSettingsSave()]));
    await tester.pumpAndSettle();
    expect(_visibleFolder(tester), 'B');
    expect(_saved(root)['favoriteFolder'], {'name': 'B', 'isNetwork': false});
  });

  testWidgets(
    'pending-save back exits search without replaying a parent back',
    (tester) async {
      final root = await _prepare(tester);
      await _createChildForNavigation(tester);
      await tester.pumpWidget(_host(const FavoritesPage()));
      await _saveFolderSelection(tester, 'Child');
      final release = Completer<void>();
      final exclusive = AppDataOperations.instance.run(() => release.future);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      tester
          .widget<FavoritesFolderSidebar>(find.byType(FavoritesFolderSidebar))
          .onFolderSelected(false, 'Child');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(LocalFavoritesPage),
          matching: find.byIcon(Icons.search),
        ),
      );
      await tester.pump();
      final owner = tester.state<SettingsSaveState>(find.byType(FavoritesPage));
      await appNavigation.rootNavigatorKey.currentState!.maybePop();
      await tester.pump();
      release.complete();
      await _flush(
        tester,
        Future.wait([exclusive, owner.waitForSettingsSave()]),
      );
      await tester.pumpAndSettle();
      expect(_visibleFolder(tester), 'Child');
      expect(
        find.byKey(const ValueKey('favorite-path-parent')),
        findsOneWidget,
      );
      expect(_saved(root)['favoriteFolder'], {
        'name': 'Child',
        'isNetwork': false,
      });
    },
  );

  for (final size in [const Size(375, 800), const Size(1024, 600)]) {
    for (final folder in [localAllFolderLabel, 'A']) {
      final label = folder == localAllFolderLabel ? 'All' : 'real folder';
      testWidgets(
        '$label selection survives storage reopen at width ${size.width}',
        (tester) async {
          final root = await _prepare(tester);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final manager = _favoritesForView();
          await tester.runAsync(
            () => manager.addComic(
              'A',
              FavoriteItem(
                id: 'persisted-comic',
                name: 'Persisted comic',
                coverPath: '',
                author: '',
                type: ComicType.local,
                tags: const [],
              ),
            ),
          );
          await tester.pumpWidget(_host(const FavoritesPage()));
          await _saveFolderSelection(tester, folder);
          expect(_saved(root)['favoriteFolder'], {
            'name': folder,
            'isNetwork': false,
          });
          await _reopenSavedView(tester, root);
          expect(find.text('Unselected'), findsNothing);
          expect(
            tester
                .widget<LocalFavoritesPage>(find.byType(LocalFavoritesPage))
                .folder,
            folder,
          );
          expect(
            tester
                .widget<FavoritesFolderSidebar>(
                  find.byType(FavoritesFolderSidebar),
                )
                .selectedFolder,
            folder,
          );
          expect(manager.getFolderComics('A').single.id, 'persisted-comic');
          expect(manager.findLinked('A'), ('test-source', 'remote-A'));
          expect(manager.existsFolder(localAllFolderLabel), isFalse);
          expect(_saved(root)['unrelated'], 42);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('All selection survives restart without real folders', (
    tester,
  ) async {
    final root = await _prepare(tester);
    final manager = _favoritesForView();
    await tester.runAsync(() async {
      for (final folder in manager.folderNames) {
        await manager.deleteFolder(folder);
      }
    });
    await tester.pumpWidget(_host(const FavoritesPage()));
    await _saveFolderSelection(tester, localAllFolderLabel);
    await _reopenSavedView(tester, root);
    expect(
      tester.widget<LocalFavoritesPage>(find.byType(LocalFavoritesPage)).folder,
      localAllFolderLabel,
    );
    expect(manager.folderNames, isEmpty);
    expect(find.text('Unselected'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleted real folder is not restored after restart', (
    tester,
  ) async {
    final root = await _prepare(tester);
    final manager = _favoritesForView();
    final remainingFolders = manager.folderNames
        .where((folder) => folder != 'A')
        .toList();
    await tester.pumpWidget(_host(const FavoritesPage()));
    await _saveFolderSelection(tester, 'A');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() => manager.deleteFolder('A'));
    await _reopenSavedView(tester, root);
    expect(find.byType(LocalFavoritesPage), findsNothing);
    expect(find.text('Unselected'), findsOneWidget);
    expect(manager.folderNames, remainingFolders);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing saved selection remains unselected', (tester) async {
    await _prepare(tester);
    await tester.pumpWidget(_host(const FavoritesPage()));
    expect(find.byType(LocalFavoritesPage), findsNothing);
    expect(find.text('Unselected'), findsOneWidget);
    expect(appdata.implicitData['favoriteFolder'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable network selection does not open local All', (
    tester,
  ) async {
    await _prepare(tester);
    appdata.implicitData['favoriteFolder'] = {
      'name': localAllFolderLabel,
      'isNetwork': true,
    };
    await tester.pumpWidget(_host(const FavoritesPage()));
    expect(find.byType(LocalFavoritesPage), findsNothing);
    expect(find.text('Unselected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
            importFolder: (_, source, pages, folder, remote) async {
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
                    importFolder: (_, _, _, _, _) async {
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
      _libraryView(
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

String _visibleFolder(WidgetTester tester) =>
    tester.widget<LocalFavoritesPage>(find.byType(LocalFavoritesPage)).folder;

Future<void> _createChildForNavigation(WidgetTester tester) => tester.runAsync(
  () async {
    final manager = _favoritesForView();
    await manager.createChildFolder('Child', manager.folderTree.named('B')!.id);
  },
);

Widget _nestedHost(Widget child) {
  final navigatorKey = GlobalKey<NavigatorState>();
  appNavigation.mainNavigatorKey = navigatorKey;
  return _libraryView(
    MaterialApp(
      navigatorKey: appNavigation.rootNavigatorKey,
      home: NaviPane(
        paneItems: [
          PaneItemEntry(
            label: 'Favorites',
            icon: Icons.favorite_outline,
            activeIcon: Icons.favorite,
          ),
        ],
        paneActions: const [],
        pageBuilder: (_) => child,
        observer: NaviObserver(),
        navigatorKey: navigatorKey,
      ),
    ),
  );
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  return FavoritesScope(
    manager: _favoritesForView(),
    child: HistoryScope(manager: _historyForView(), child: child),
  );
}
