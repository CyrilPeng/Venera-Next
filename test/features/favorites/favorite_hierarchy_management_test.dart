import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/tv_navigation.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/favorites/favorite_actions.dart';
import 'package:venera_next/features/favorites/favorite_folder_browser.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/favorites/folder_move_dialog.dart';
import 'package:venera_next/features/favorites/folder_order_dialog.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/routing/app_navigation.dart';

import '../../components/sidebar_presentation_test.dart'
    show pumpSidebar, settleSidebarWork;

class _Host {
  final manager = LocalFavoritesManager.independent();
  final registry = SelectionTaskRegistry();
  final messages = <String>[];
  late BuildContext context;
  late Directory root;
  int committed = 0;
  double textScale = 1;
  bool dark = false;
  bool? tv;
  Widget content = const SizedBox();

  Future<void> mount(WidgetTester tester) async {
    final settings = appdata.captureImportCheckpoint();
    root = Directory.systemTemp.createTempSync('favorite-hierarchy-ui-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings['language'] = 'en-US';
    registerShowMessageHandler((_, message) => messages.add(message));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await pumpSidebar(tester);
      await settleSidebarWork(tester, registry.closeAndWait);
      await tester.runAsync(() async {
        await AppDataOperations.instance.run(() async {});
        await manager.closeAndWait();
        await appdata.saveData(false);
        await appdata.restoreImportCheckpoint(settings, persist: false);
      });
      registerShowMessageHandler((_, _) {});
      final temporary = Directory.systemTemp.resolveSymbolicLinksSync();
      final owned = root.resolveSymbolicLinksSync();
      expect(p.isWithin(temporary, owned), isTrue);
      expect(p.basename(owned), startsWith('favorite-hierarchy-ui-'));
      root.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await manager.init();
      await manager.createFolder('Parent');
      await manager.createFolder('Other');
    });
    await tester.pumpWidget(
      FavoritesScope(
        manager: manager,
        child: SelectionTasksScope(
          registry: registry,
          child: MaterialApp(
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: true,
              ),
              child: TvNavigation(
                enabled: tv,
                onBack: () => unawaited(
                  appNavigation.rootNavigatorKey.currentState!.maybePop(),
                ),
                child: child!,
              ),
            ),
            navigatorKey: appNavigation.rootNavigatorKey,
            home: Builder(
              builder: (value) {
                context = value;
                return Scaffold(body: content);
              },
            ),
          ),
        ),
      ),
    );
    await pumpSidebar(tester);
  }

  Future<void> move(String name) => moveFavoriteFolder(
    context,
    folder: name,
    isCurrent: () => true,
    onCommitted: () => committed++,
  );
}

Future<void> _remoteActivate(WidgetTester tester, Finder target) async {
  final focus = Focus.of(tester.element(target));
  focus.requestFocus();
  await pumpSidebar(tester);
  expect(focus.hasPrimaryFocus, isTrue);
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await pumpSidebar(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });

  testWidgets(
    'creation selects a root parent and creates a second-level folder',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final showing = newFolder(host.context);
      await pumpSidebar(tester);
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-name')),
        'Child',
      );
      tester
          .widget<FavoriteFolderSelect>(find.byType(FavoriteFolderSelect))
          .onChanged!('Parent');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await settleSidebarWork(tester, () => showing);
      expect(host.manager.folderTree.label('Child'), 'Parent / Child');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a retired parent cannot silently create a root folder', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final parent = host.manager.folderTree.named('Parent')!;
    await tester.runAsync(() => host.manager.deleteFolder('Parent'));
    await newFolder(host.context, parentId: parent.id);
    await pumpSidebar(tester);
    expect(find.byKey(const ValueKey('favorite-folder-name')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (size: const Size(375, 740), dark: false),
    (size: const Size(812, 375), dark: true),
  ]) {
    testWidgets(
      'nested parent picker and creation remain usable at large text: $scenario',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = _Host()
          ..textScale = 2
          ..dark = scenario.dark;
        await host.mount(tester);
        final showing = newFolder(
          host.context,
          parentId: host.manager.folderTree.named('Parent')!.id,
        );
        await pumpSidebar(tester);
        await tester.ensureVisible(find.byType(FavoriteFolderSelect));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FavoriteFolderSelect));
        await pumpSidebar(tester);
        await tester.enterText(
          find.byKey(const ValueKey('favorite-folder-search')),
          'Other',
        );
        await tester.pump();
        await tester.scrollUntilVisible(
          find.widgetWithText(ListTile, 'Other'),
          80,
          scrollable: find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.widgetWithText(ListTile, 'Other'));
        await pumpSidebar(tester);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.ensureVisible(
          find.byKey(const ValueKey('favorite-folder-name')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('favorite-folder-name')),
          'Child',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await settleSidebarWork(tester, () => showing);
        expect(host.manager.folderTree.label('Child'), 'Other / Child');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'move and restore change only ancestry, not contents or references',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await tester.runAsync(() async {
        await host.manager.addComic(
          'Other',
          FavoriteItem(
            id: 'kept',
            name: 'Kept',
            author: '',
            coverPath: '',
            type: ComicType.local,
            tags: const [],
          ),
        );
        await host.manager.linkFolderToNetwork('Other', 'source', 'remote');
        await appdata.updateSettings(
          (draft) => draft['quickFavorite'] = 'Other',
        );
      });
      final original = host.manager.folderTree.named('Other')!.id;
      for (final parent in <String?>['Parent', null]) {
        final showing = host.move('Other');
        await pumpSidebar(tester);
        await tester.tap(find.byType(FavoriteFolderSelect));
        await pumpSidebar(tester);
        await tester.tap(
          find.widgetWithText(ListTile, parent ?? 'First-level folder'),
        );
        await pumpSidebar(tester);
        expect(find.byType(AlertDialog), findsNothing);
        tester
            .widget<Button>(find.widgetWithText(Button, 'Confirm'))
            .onPressed();
        await settleSidebarWork(tester, () => showing);
        expect(host.manager.folderTree.named('Other')!.id, original);
        expect(
          host.manager.folderTree.label('Other'),
          parent == null ? 'Other' : 'Parent / Other',
        );
        expect(host.manager.getFolderComics('Other').single.id, 'kept');
        expect(host.manager.findLinked('Other'), ('source', 'remote'));
        expect(appdata.settings['quickFavorite'], 'Other');
      }
      expect(host.committed, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bulk addition selects a child through the owned searchable picker',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await tester.runAsync(
        () => host.manager.createChildFolder(
          'Child',
          host.manager.folderTree.named('Parent')!.id,
        ),
      );
      final showing = addFavorite(host.context, [
        FavoriteItem(
          id: 'new',
          name: 'New',
          author: '',
          coverPath: '',
          type: ComicType.local,
          tags: const [],
        ),
      ]);
      await pumpSidebar(tester);
      await tester.tap(find.byType(FavoriteFolderSelect));
      await pumpSidebar(tester);
      await tester.enterText(
        find.byKey(const ValueKey('favorite-folder-search')),
        'Child',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'Child'));
      await pumpSidebar(tester);
      expect(find.byType(AlertDialog), findsNothing);
      tester.widget<Button>(find.widgetWithText(Button, 'Confirm')).onPressed();
      await settleSidebarWork(tester, () => showing);
      expect(host.manager.getFolderComics('Child').single.id, 'new');
      expect(host.manager.getFolderComics('Parent'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'parent page exposes children, blocks deletion and labels direct-only export',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      await tester.runAsync(
        () => host.manager.createChildFolder(
          'Child',
          host.manager.folderTree.named('Parent')!.id,
        ),
      );
      await tester.pumpWidget(
        FavoritesScope(
          manager: host.manager,
          child: MaterialApp(
            home: Scaffold(
              body: LocalFavoritesPage(
                folder: 'Parent',
                showFolders: () {},
                onFolderSelected: (_, _) {},
                updateFolderList: () {},
              ),
            ),
          ),
        ),
      );
      await pumpSidebar(tester);
      expect(find.widgetWithText(ListTile, 'Child'), findsOneWidget);
      final entries = tester
          .widgetList<MenuButton>(find.byType(MenuButton))
          .expand((menu) => menu.entries)
          .toList();
      expect(
        entries.any(
          (entry) => entry.text == 'Export this folder only (no subfolders)',
        ),
        isTrue,
      );
      entries.singleWhere((entry) => entry.text == 'Delete Folder').onClick();
      await pumpSidebar(tester);
      expect(
        host.messages,
        contains('Move subfolders before deleting this folder'),
      );
      expect(host.manager.folderNames, containsAll(['Parent', 'Child']));
      final json = jsonDecode(host.manager.folderToJson('Parent')) as Map;
      expect(json['comics'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('root and child sorting preserve IDs and affect only siblings', (
    tester,
  ) async {
    final host = _Host();
    await host.mount(tester);
    final parent = host.manager.folderTree.named('Parent')!;
    await tester.runAsync(() async {
      await host.manager.createChildFolder('First child', parent.id);
      await host.manager.createChildFolder('Second child', parent.id);
    });
    final ids = {
      for (final folder in host.manager.folderTree.flattened)
        folder.name: folder.id,
    };
    final roots = host.manager.folderTree.roots
        .map((folder) => folder.name)
        .toList();
    final showing = sortFolders(host.context);
    await pumpSidebar(tester);
    final rootList = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    rootList.onReorder(0, roots.length);
    await tester.pump();
    tester
        .widget<FavoriteFolderSelect>(find.byType(FavoriteFolderSelect))
        .onChanged!('Parent');
    await tester.pump();
    await tester.tap(find.byTooltip('Move down').first);
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_back_sharp));
    await settleSidebarWork(tester, () => showing);
    final tree = host.manager.folderTree;
    expect(tree.roots.map((folder) => folder.name), [
      ...roots.skip(1),
      roots.first,
    ]);
    expect(tree.childrenOf(parent.id).map((folder) => folder.name), [
      'Second child',
      'First child',
    ]);
    expect({for (final folder in tree.flattened) folder.name: folder.id}, ids);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote moves a child through its nested parent picker', (
    tester,
  ) async {
    final host = _Host()..tv = true;
    await host.mount(tester);
    final parent = host.manager.folderTree.named('Parent')!;
    await tester.runAsync(
      () => host.manager.createChildFolder('Child', parent.id),
    );
    final original = host.manager.folderTree.named('Child')!;
    final showing = host.move('Child');
    await pumpSidebar(tester);
    await _remoteActivate(tester, find.text('Parent'));
    await _remoteActivate(tester, find.text('Other'));
    await _remoteActivate(tester, find.text('Confirm'));
    await settleSidebarWork(tester, () => showing);
    final moved = host.manager.folderTree.named('Child')!;
    expect(moved.id, original.id);
    expect(moved.parentId, host.manager.folderTree.named('Other')!.id);
    expect(host.committed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote sorts siblings without dragging and saves on back', (
    tester,
  ) async {
    final host = _Host()..tv = true;
    await host.mount(tester);
    final parent = host.manager.folderTree.named('Parent')!;
    await tester.runAsync(() async {
      await host.manager.createChildFolder('First child', parent.id);
      await host.manager.createChildFolder('Second child', parent.id);
    });
    final roots = host.manager.folderTree.roots.map((folder) => folder.id);
    final ids = {
      for (final folder in host.manager.folderTree.flattened)
        folder.name: folder.id,
    };
    final showing = sortFolders(host.context);
    await pumpSidebar(tester);
    await _remoteActivate(tester, find.text('First-level folder'));
    await _remoteActivate(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Parent'),
      ),
    );
    await _remoteActivate(
      tester,
      find.descendant(
        of: find.byTooltip('Move down').first,
        matching: find.byIcon(Icons.arrow_downward),
      ),
    );
    await tester.sendKeyEvent(
      LogicalKeyboardKey.goBack,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await settleSidebarWork(tester, () => showing);
    final tree = host.manager.folderTree;
    expect(tree.childrenOf(parent.id).map((folder) => folder.name), [
      'Second child',
      'First child',
    ]);
    expect(tree.roots.map((folder) => folder.id), roots);
    expect({for (final folder in tree.flattened) folder.name: folder.id}, ids);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(812, 375), const Size(1920, 1080)]) {
    testWidgets(
      'sorting groups with long names fit the popup at large text: $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = _Host()..textScale = 2;
        await host.mount(tester);
        const name = 'A deliberately long parent folder for sorting';
        await tester.runAsync(() async {
          await host.manager.rename('Parent', name);
          await host.manager.createChildFolder(
            'Child',
            host.manager.folderTree.named(name)!.id,
          );
        });
        final showing = sortFolders(host.context);
        await pumpSidebar(tester);
        expect(tester.takeException(), isNull);
        tester
            .widget<FavoriteFolderSelect>(find.byType(FavoriteFolderSelect))
            .onChanged!(name);
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.arrow_back_sharp),
        );
        await settleSidebarWork(tester, () => showing);
        expect(host.manager.folderTree.label('Child'), '$name / Child');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a queued move cannot target a replacement database with the same names',
    (tester) async {
      final host = _Host();
      await host.mount(tester);
      final showing = host.move('Other');
      await pumpSidebar(tester);
      tester
          .widget<FavoriteFolderSelect>(find.byType(FavoriteFolderSelect))
          .onChanged!('Parent');
      await tester.pump();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final replacement = AppDataOperations.instance.run(() async {
        await release.future;
        await host.manager.closeAndWait();
        App.dataPath = (Directory(
          p.join(host.root.path, 'replacement'),
        )..createSync()).path;
        await host.manager.init();
        await host.manager.createFolder('Parent');
        await host.manager.createFolder('Other');
      });
      tester.widget<Button>(find.widgetWithText(Button, 'Confirm')).onPressed();
      await pumpSidebar(tester);
      release.complete();
      await settleSidebarWork(tester, () => replacement);
      await settleSidebarWork(
        tester,
        () => AppDataOperations.instance.run(() async {}),
      );
      await pumpSidebar(tester);
      expect(host.manager.folderTree.named('Other')!.parentId, isNull);
      expect(host.committed, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settleSidebarWork(tester, () => showing);
      expect(tester.takeException(), isNull);
    },
  );
}
