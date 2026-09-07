import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';

List<String> _comicOrder(WidgetTester tester) {
  final builder = tester.widget<ReorderableBuilder<FavoriteItem>>(
    find.byType(ReorderableBuilder<FavoriteItem>),
  );
  return builder.children!
      .cast<ComicTile>()
      .map((tile) => tile.comic.id)
      .toList();
}

Future<void> _openReorder(WidgetTester tester) async {
  final menu = find.byWidgetPredicate(
    (widget) =>
        widget is MenuButton &&
        widget.entries.any((entry) => entry.text == 'Reorder'),
  );
  tester
      .widget<MenuButton>(menu)
      .entries
      .singleWhere((entry) => entry.text == 'Reorder')
      .onClick();
  await tester.pumpAndSettle();
  expect(find.byType(ReorderableBuilder<FavoriteItem>), findsOneWidget);
}

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'favorite ${kind.name} drag order survives reopening',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'venera-favorite-order-',
        );
        final previousSettings = {
          for (final key in [
            'comicDisplayMode',
            'followUpdatesFolder',
            'quickFavorite',
            'language',
          ])
            key: appdata.settings[key],
        };
        final previousImplicit = Map<String, dynamic>.from(
          appdata.implicitData,
        );
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        LocalFavoritesManager.cache = null;
        HistoryManager.cache = null;
        var manager = LocalFavoritesManager();
        final history = HistoryManager();
        appdata.settings['comicDisplayMode'] = 'detailed';
        appdata.settings['language'] = 'en-US';
        appdata.implicitData['favoriteFolder'] = {
          'name': 'Reorder test',
          'isNetwork': false,
        };
        appdata.implicitData['local_favorites_read_filter'] = 'All';
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 300));
          await tester.runAsync(() async {
            await manager.debugWaitForHashedIdsRefresh();
            await appdata.saveData(false);
            manager.close();
            history.close();
          });
          LocalFavoritesManager.cache = null;
          HistoryManager.cache = null;
          for (final entry in previousSettings.entries) {
            appdata.settings[entry.key] = entry.value;
          }
          appdata.implicitData = previousImplicit;
          directory.deleteSync(recursive: true);
        });
        tester.view.physicalSize = const Size(900, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pump();
        await tester.runAsync(() async {
          await manager.init();
          await history.init();
          manager.createFolder('Reorder test');
          for (var i = 0; i < 6; i++) {
            manager.addComic(
              'Reorder test',
              FavoriteItem(
                id: 'comic-$i',
                name: 'Comic $i',
                coverPath: '',
                author: '',
                type: ComicType.local,
                tags: const [],
              ),
              i,
            );
          }
          await manager.debugWaitForHashedIdsRefresh();
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const Scaffold(body: FavoritesPage()),
          ),
        );
        await tester.pumpAndSettle();
        await _openReorder(tester);
        expect(_comicOrder(tester), [for (var i = 0; i < 6; i++) 'comic-$i']);

        Finder tile(String id) => find.byWidgetPredicate(
          (widget) => widget is ComicTile && widget.comic.id == id,
        );
        final target = tester.getCenter(tile('comic-2'));
        final builder = tester.widget<ReorderableBuilder<FavoriteItem>>(
          find.byType(ReorderableBuilder<FavoriteItem>),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(tile('comic-0')),
          kind: kind,
        );
        await tester.pump(
          builder.longPressDelay + const Duration(milliseconds: 50),
        );
        await gesture.moveTo(target);
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();
        const expected = [
          'comic-1',
          'comic-2',
          'comic-0',
          'comic-3',
          'comic-4',
          'comic-5',
        ];
        expect(_comicOrder(tester), expected);

        App.rootNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          manager.getFolderComics('Reorder test').map((comic) => comic.id),
          expected,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await manager.debugWaitForHashedIdsRefresh();
          manager.close();
          LocalFavoritesManager.cache = null;
          manager = LocalFavoritesManager();
          await manager.init();
          await manager.debugWaitForHashedIdsRefresh();
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: const Scaffold(body: FavoritesPage()),
          ),
        );
        await tester.pumpAndSettle();
        await _openReorder(tester);
        expect(_comicOrder(tester), expected);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
      },
      skip: !_sqliteAvailable(),
    );
  }
}
