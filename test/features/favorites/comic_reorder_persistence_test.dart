import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/appbar.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/settings_save_state.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_page.dart';
import 'package:venera_next/features/history/history.dart';
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

class _History extends Fake implements HistoryManager {
  @override
  History? find(String id, ComicType type) => null;
}

List<Map<String, Object?>> _rows(LocalFavoritesManager manager, String query) {
  final database = sqlite3.open(manager.databasePath);
  try {
    return database
        .select(query)
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  } finally {
    database.dispose();
  }
}

void _sql(LocalFavoritesManager manager, String sql) {
  final database = sqlite3.open(manager.databasePath);
  try {
    database.execute(sql);
  } finally {
    database.dispose();
  }
}

List<Map<String, Object?>> _metadata(List<Map<String, Object?>> rows) => [
  for (final row in rows) Map.of(row)..remove('display_order'),
];

SettingsSaveState _saveOwner(WidgetTester tester) {
  SettingsSaveState? owner;
  tester
      .element(find.byType(ReorderableBuilder<FavoriteItem>))
      .visitAncestorElements((element) {
        if (element is StatefulElement && element.state is SettingsSaveState) {
          owner = element.state as SettingsSaveState;
          return false;
        }
        return true;
      });
  return owner!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;
  for (final failFirst in [false, true]) {
    testWidgets(
      'actual comic order keeps row identity, metadata and parent: rollback=$failFirst',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'venera-comic-order-owned-',
        );
        final previousData = App.dataPath;
        final previousCache = App.cachePath;
        final previousManager = LocalFavoritesManager.cache;
        final previousHistory = HistoryManager.cache;
        final checkpoint = appdata.captureImportCheckpoint();
        final muted = Log.isMuted;
        final registry = SelectionTaskRegistry();
        Log.isMuted = true;
        App.dataPath = root.path;
        App.cachePath = root.path;
        LocalFavoritesManager.cache = null;
        HistoryManager.cache = _History();
        final manager = LocalFavoritesManager();
        registerShowMessageHandler((_, _) {});
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await pumpSidebar(tester);
          await settleSidebarWork(tester, registry.closeAndWait);
          await tester.runAsync(() async {
            await AppDataOperations.instance.run(() async {});
            await manager.closeAndWait();
            await appdata.restoreImportCheckpoint(checkpoint, persist: false);
          });
          LocalFavoritesManager.cache = previousManager;
          HistoryManager.cache = previousHistory;
          App.dataPath = previousData;
          App.cachePath = previousCache;
          Log.isMuted = muted;
          final temporaryRoot = Directory.systemTemp.resolveSymbolicLinksSync();
          final owned = root.resolveSymbolicLinksSync();
          expect(p.isWithin(temporaryRoot, owned), isTrue);
          expect(p.basename(owned), startsWith('venera-comic-order-owned-'));
          root.deleteSync(recursive: true);
        });
        appdata.settings['language'] = 'en-US';
        appdata.settings['favoritesDisplayMode'] = 'list';
        appdata.settings['followUpdatesFolder'] = 'Original';
        appdata.implicitData['local_favorites_read_filter'] = 'All';
        appdata.implicitData['favoriteFolder'] = {
          'name': 'Original',
          'isNetwork': false,
        };
        await tester.runAsync(() async {
          await manager.init();
          await manager.createFolder('Original');
          await manager.createFolder('Other');
          await manager.prepareTableForFollowUpdates('Original');
          await manager.linkFolderToNetwork(
            'Original',
            'synthetic-source',
            'remote-folder',
          );
          final comics = [
            FavoriteItem.withTime(
              id: 'shared',
              name: 'Local',
              coverPath: '',
              author: 'author-a',
              type: ComicType.local,
              tags: ['tag:a'],
              time: '2020-01-02 03:04:05',
            ),
            FavoriteItem.withTime(
              id: 'shared',
              name: 'Remote',
              coverPath: '',
              author: 'author-b',
              type: const ComicType(719531),
              tags: ['tag:b'],
              time: '2021-02-03 04:05:06',
            ),
            FavoriteItem.withTime(
              id: 'last',
              name: 'Last',
              coverPath: '',
              author: 'author-c',
              type: ComicType.local,
              tags: ['tag:c'],
              time: 'legacy-time-value',
            ),
          ];
          for (var i = 0; i < comics.length; i++) {
            await manager.addComic('Original', comics[i], i);
          }
          await manager.updateOrder(['Original', 'Other']);
          await manager.debugWaitForHashedIdsRefresh();
        });
        _sql(
          manager,
          "UPDATE Original SET last_update_time = 'original update', has_new_update = 1, last_check_time = 123, translated_tags = 'original translated tags';",
        );
        final originalRows = _rows(
          manager,
          'SELECT rowid, * FROM Original ORDER BY rowid',
        );
        final folderOrder = _rows(
          manager,
          'SELECT * FROM folder_order ORDER BY order_value',
        );
        final folderLinks = _rows(
          manager,
          'SELECT * FROM folder_sync ORDER BY folder_name',
        );
        final originalOrder = manager
            .getFolderComics('Original')
            .map((comic) => (comic.id, comic.type.value))
            .toList();
        var notifications = 0;
        void notified() => notifications++;
        manager.addListener(notified);
        addTearDown(() => manager.removeListener(notified));
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: appNavigation.rootNavigatorKey,
            builder: (_, child) =>
                SelectionTasksScope(registry: registry, child: child!),
            home: const Scaffold(body: FavoritesPage()),
          ),
        );
        await pumpSidebar(tester);
        final parent = tester.element(
          find.byKey(const PageStorageKey('local_Original')),
        );
        tester
            .widgetList<MenuButton>(find.byType(MenuButton))
            .expand((menu) => menu.entries)
            .singleWhere((entry) => entry.text == 'Reorder')
            .onClick();
        await pumpSidebar(tester);
        final editor = _saveOwner(tester);
        if (failFirst) {
          _sql(
            manager,
            "CREATE TRIGGER reject_order BEFORE UPDATE OF display_order ON Original WHEN NEW.id = 'shared' AND NEW.type = ${ComicType.local.value} BEGIN SELECT RAISE(ABORT, 'synthetic middle write failure'); END;",
          );
        }
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.swap_vert),
            )
            .onPressed!();
        Object? failure;
        await settleSidebarWork(tester, () async {
          try {
            await editor.waitForSettingsSave();
          } catch (error) {
            failure = error;
          }
        });
        await pumpSidebar(tester);
        if (failFirst) {
          expect(failure, isA<SqliteException>());
          expect(
            failure.toString(),
            contains('synthetic middle write failure'),
          );
          expect(
            _rows(manager, 'SELECT rowid, * FROM Original ORDER BY rowid'),
            originalRows,
          );
          expect(notifications, 0);
          _sql(manager, 'DROP TRIGGER reject_order;');
          tester
              .widget<TextButton>(
                find.descendant(
                  of: find.byType(Appbar),
                  matching: find.widgetWithText(TextButton, 'Retry'),
                ),
              )
              .onPressed!();
          await settleSidebarWork(tester, editor.waitForSettingsSave);
          await pumpSidebar(tester);
        } else {
          expect(failure, isNull);
        }
        expect(notifications, 1);
        expect(
          _metadata(
            _rows(manager, 'SELECT rowid, * FROM Original ORDER BY rowid'),
          ),
          _metadata(originalRows),
        );
        expect(
          _rows(manager, 'SELECT * FROM folder_order ORDER BY order_value'),
          folderOrder,
        );
        expect(
          _rows(manager, 'SELECT * FROM folder_sync ORDER BY folder_name'),
          folderLinks,
        );
        expect(
          manager
              .getFolderComics('Original')
              .map((comic) => (comic.id, comic.type.value)),
          originalOrder.reversed,
        );
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_back),
            )
            .onPressed!();
        await pumpSidebar(tester);
        expect(parent.mounted, isTrue);
        expect(find.byType(ReorderableBuilder<FavoriteItem>), findsNothing);
        expect(
          tester
              .widget<SliverGridComics>(find.byType(SliverGridComics))
              .comics
              .map((comic) => comic.title),
          ['Last', 'Remote', 'Local'],
        );
        await tester.pumpWidget(const SizedBox());
        await pumpSidebar(tester);
        await settleSidebarWork(tester, registry.closeAndWait);
        await tester.runAsync(() async {
          await manager.closeAndWait();
          await manager.init();
        });
        expect(
          manager
              .getFolderComics('Original')
              .map((comic) => (comic.id, comic.type.value)),
          originalOrder.reversed,
        );
        expect(
          _metadata(
            _rows(manager, 'SELECT rowid, * FROM Original ORDER BY rowid'),
          ),
          _metadata(originalRows),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
