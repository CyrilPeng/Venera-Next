import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/favorites/favorite_folder_browser.dart';
import 'package:venera_next/features/favorites/local_favorites_page.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/routing/app_navigation.dart';

FavoriteItem _comic(String id, String title) => FavoriteItem(
  id: id,
  name: title,
  author: '',
  type: const ComicType(17),
  tags: const [],
  coverPath: '',
);

Finder _tile(String id) => find.byWidgetPredicate(
  (widget) => widget is ComicTile && widget.comic.id == id,
);

class _Fixture {
  final manager = LocalFavoritesManager.independent();
  final history = _ObservedHistory();
  final navigator = appNavigation.rootNavigatorKey;
  double textScale = 1;
  bool dark = false;
  double keyboardInset = 0;

  Widget host({String folder = 'B'}) => FavoritesScope(
    manager: manager,
    child: HistoryScope(
      manager: history,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        builder: (context, child) => Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.escape): VoidCallbackIntent(
              appNavigation.pop,
            ),
          },
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              viewInsets: EdgeInsets.only(bottom: keyboardInset),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: LocalFavoritesPage(
            folder: folder,
            showFolders: () {},
            onFolderSelected: (_, _) {},
            updateFolderList: () {},
          ),
        ),
      ),
    ),
  );
}

class _ObservedHistory extends HistoryManager {
  _ObservedHistory() : super.create();

  int reads = 0;

  @override
  History? find(String id, ComicType type) {
    reads++;
    return super.find(id, type);
  }
}

Future<_Fixture> _prepare(WidgetTester tester, int count) async {
  final root = Directory('build').absolute.createTempSync('favorite-refresh-');
  final buildRoot = Directory('build').resolveSymbolicLinksSync();
  final previousPath = App.dataPath;
  final previousCachePath = App.cachePath;
  final settings = Map<String, dynamic>.from(
    appdata.toJson()['settings'] as Map,
  );
  final implicit = appdata.implicitData;
  final fixture = _Fixture();
  App.dataPath = root.path;
  App.cachePath = root.path;
  appdata.settings['language'] = 'en-US';
  appdata.settings[FavoritePreferences.newFavoriteAddTo.key] = 'start';
  appdata.settings['blockedWords'] = <String>[];
  appdata.settings[KeywordPreferences.comics.key] = <String>[];
  appdata.settings['showFavoriteStatusOnTile'] = false;
  appdata.settings['showHistoryStatusOnTile'] = false;
  appdata.settings['showUpdateStatusOnTile'] = false;
  appdata.implicitData = {'local_favorites_read_filter': 'All'};
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (_) async => false,
  );
  configureComicWidgets(
    addStateListener: (listener) {
      fixture.manager.addListener(listener);
      fixture.history.addListener(listener);
    },
    removeStateListener: (listener) {
      fixture.manager.removeListener(listener);
      fixture.history.removeListener(listener);
    },
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await fixture.manager.closeAndWait();
      fixture.history.close();
    });
    configureComicWidgets();
    settings.forEach((key, value) => appdata.settings[key] = value);
    appdata.implicitData = implicit;
    App.dataPath = previousPath;
    App.cachePath = previousCachePath;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    expect(
      root.resolveSymbolicLinksSync(),
      startsWith('$buildRoot${Platform.pathSeparator}'),
    );
    root.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await OpenCC.init();
    await fixture.manager.init();
    await fixture.history.init();
    await fixture.manager.createFolder('A');
    await fixture.manager.createFolder('B');
    if (count > 0) {
      await fixture.manager.addComics(
        'B',
        List.generate(count, (i) => _comic('seed-$i', 'Existing $i')),
      );
    }
  });
  return fixture;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (
    var i = 0;
    i < 1000 &&
        find
            .byType(CircularProgressIndicator, skipOffstage: false)
            .evaluate()
            .isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    find.byType(CircularProgressIndicator, skipOffstage: false),
    findsNothing,
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseAction(WidgetTester tester, String label) async {
  final direct = find.byTooltip(label);
  if (direct.evaluate().isNotEmpty) {
    await tester.tap(direct);
    await tester.pumpAndSettle();
    return;
  }
  final menu = find.byWidgetPredicate(
    (widget) =>
        widget is MenuButton &&
        widget.entries.any((entry) => entry.text == label),
  );
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  App.cachePath = Directory.systemTemp.path;

  for (final filtered in [false, true]) {
    testWidgets(
      'large favorites reuse filtering across keyboard layouts and follow history: filtered=$filtered',
      (tester) async {
        final fixture = await _prepare(tester, 1200);
        if (filtered) {
          appdata.implicitData['local_favorites_read_filter'] = 'Completed';
        }
        await tester.pumpWidget(fixture.host());
        await _settle(tester);
        final grid = find.byType(SliverGridComics, skipOffstage: false);
        final input = tester.widget<SliverGridComics>(grid).comics;
        final reads = fixture.history.reads;
        expect(reads, filtered ? 1200 : 0);
        for (final inset in [80.0, 160.0, 240.0, 0.0]) {
          fixture.keyboardInset = inset;
          await tester.pumpWidget(fixture.host());
          await tester.pump();
          expect(fixture.history.reads, reads);
          expect(tester.widget<SliverGridComics>(grid).comics, same(input));
        }
        await tester.runAsync(
          () => fixture.history.addHistory(
            History(
              type: const HistoryType(17),
              time: DateTime.now(),
              title: 'Existing 0',
              subtitle: '',
              cover: '',
              ep: 1,
              page: 2,
              id: 'seed-0',
              readEpisode: {'1'},
              maxPage: 2,
              readDurationMs: 0,
            ),
          ),
        );
        await _settle(tester);
        if (filtered) {
          expect(
            tester.widget<SliverGridComics>(grid).comics.single.id,
            'seed-0',
          );
          expect(fixture.history.reads, greaterThan(reads));
        } else {
          expect(fixture.history.reads, 0);
          expect(tester.widget<SliverGridComics>(grid).comics, same(input));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'wide selection toolbar exposes common actions and Escape exits local modes',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _prepare(tester, 3);
      await tester.pumpWidget(fixture.host());
      await _settle(tester);
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Existing 1');
      await tester.pumpAndSettle();
      await tester.longPress(_tile('seed-1'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('favorites-select-all')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('favorites-invert-selection')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('favorites-deselect')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Selected 1 comics'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Selected 1 comics'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(_tile('seed-0'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(_tile('seed-0'), findsOneWidget);
      expect(_tile('seed-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Escape dismisses a deletion dialog before clearing selection', (
    tester,
  ) async {
    final fixture = await _prepare(tester, 2);
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    await tester.tap(find.byTooltip('Select comics'));
    await tester.pumpAndSettle();
    await _chooseAction(tester, 'Select All');
    await _chooseAction(tester, 'Delete Comic');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 comics?'), findsNothing);
    expect(find.text('Selected 2 comics'), findsOneWidget);
    expect(fixture.manager.getFolderComics('B'), hasLength(2));
  });

  for (final size in [
    const Size(375, 800),
    const Size(812, 375),
    const Size(1024, 600),
  ]) {
    testWidgets(
      'page menu opens current subfolders and persists only their order at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final count = size.width == 1024 ? 1 : 0;
        final fixture = await _prepare(tester, count);
        fixture.textScale = count == 0 ? 2 : 1;
        fixture.dark = size.width == 375;
        final manager = fixture.manager;
        final parent = manager.folderTree.named('B')!;
        await tester.runAsync(() async {
          await manager.createChildFolder('First child', parent.id);
          await manager.createChildFolder('Second child', parent.id);
          await manager.addComic(
            'First child',
            _comic('child-comic', 'Child comic'),
          );
        });
        final roots = manager.folderTree.roots
            .map((folder) => folder.id)
            .toList();
        final identities = {
          for (final folder in manager.folderTree.flattened)
            folder.name: (folder.id, folder.parentId),
        };
        await tester.pumpWidget(fixture.host());
        await _settle(tester);
        await _chooseAction(tester, 'Sort subfolders');
        expect(
          tester
              .widget<FavoriteFolderSelect>(find.byType(FavoriteFolderSelect))
              .current,
          'B',
        );
        expect(
          tester
              .widget<ReorderableListView>(find.byType(ReorderableListView))
              .itemCount,
          2,
        );
        await tester.tap(find.byTooltip('Move down').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithIcon(IconButton, Icons.arrow_back_sharp),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => AppDataOperations.instance.run(() async {}),
        );
        await _settle(tester);
        expect(
          manager.folderTree.childrenOf(parent.id).map((folder) => folder.name),
          ['Second child', 'First child'],
        );
        expect(manager.folderTree.roots.map((folder) => folder.id), roots);
        expect({
          for (final folder in manager.folderTree.flattened)
            folder.name: (folder.id, folder.parentId),
        }, identities);
        expect(
          manager.getFolderComics('B').map((comic) => comic.id),
          count == 0 ? isEmpty : ['seed-0'],
        );
        expect(manager.getFolderComics('First child').single.id, 'child-comic');
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await manager.closeAndWait();
          await manager.init();
        });
        expect(
          manager.folderTree.childrenOf(parent.id).map((folder) => folder.name),
          ['Second child', 'First child'],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('old folder action cannot open a different page hierarchy', (
    tester,
  ) async {
    final fixture = await _prepare(tester, 1);
    await tester.runAsync(
      () => fixture.manager.createChildFolder(
        'Child',
        fixture.manager.folderTree.named('B')!.id,
      ),
    );
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    final retained = tester
        .widget<MenuButton>(find.byType(MenuButton))
        .entries
        .singleWhere((entry) => entry.text == 'Sort subfolders')
        .onClick;
    await tester.pumpWidget(fixture.host(folder: 'A'));
    await _settle(tester);
    retained();
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(375, 800), const Size(1024, 600)]) {
    testWidgets('explicit selection entry and confirmed deletion at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _prepare(tester, 3);
      await tester.pumpWidget(fixture.host());
      await _settle(tester);
      if (size.width < 600) {
        await _chooseAction(tester, 'Select comics');
      } else {
        await tester.tap(find.byTooltip('Select comics'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Selected 0 comics'), findsOneWidget);
      expect(
        tester
            .widget<MenuButton>(find.byType(MenuButton))
            .entries
            .any((entry) => entry.text == 'Delete Comic'),
        isFalse,
      );
      await _chooseAction(tester, 'Select All');
      expect(find.text('Selected 3 comics'), findsOneWidget);
      await _chooseAction(tester, 'Delete Comic');
      expect(find.text('Delete 3 comics?'), findsOneWidget);
      expect(fixture.manager.getFolderComics('B'), hasLength(3));
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(fixture.manager.getFolderComics('B'), hasLength(3));
      expect(find.text('Selected 3 comics'), findsOneWidget);
      await _chooseAction(tester, 'Delete Comic');
      await tester.tap(find.text('Confirm').last);
      await _settle(tester);
      expect(fixture.manager.getFolderComics('B'), isEmpty);
      expect(find.text('Selected 3 comics'), findsNothing);
      expect(find.text('Selected 0 comics'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('select all and invert use only visible favorite records', (
    tester,
  ) async {
    final fixture = await _prepare(tester, 3);
    appdata.settings[KeywordPreferences.comics.key] = <String>['Existing 1'];
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    await tester.tap(find.byTooltip('Select comics'));
    await tester.pumpAndSettle();
    await _chooseAction(tester, 'Select All');
    expect(find.text('Selected 2 comics'), findsOneWidget);
    final grid = tester.widget<SliverGridComics>(find.byType(SliverGridComics));
    expect(
      grid.selections!.keys.map((comic) => comic.id),
      unorderedEquals(['seed-0', 'seed-2']),
    );
    await _chooseAction(tester, 'Invert Selection');
    expect(find.text('Selected 0 comics'), findsOneWidget);
    await _chooseAction(tester, 'Invert Selection');
    expect(find.text('Selected 2 comics'), findsOneWidget);
    await tester.tap(_tile('seed-0'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 1 comics'), findsOneWidget);
    appdata.settings[KeywordPreferences.comics.key] = <String>['Existing 2'];
    await tester.pumpAndSettle();
    expect(find.text('Selected 1 comics'), findsNothing);
    expect(
      tester.widget<SliverGridComics>(find.byType(SliverGridComics)).selections,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection entry clears on back and on folder changes', (
    tester,
  ) async {
    final fixture = await _prepare(tester, 2);
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    await tester.tap(find.byTooltip('Select comics'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 0 comics'), findsOneWidget);
    await fixture.navigator.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Selected 0 comics'), findsNothing);
    await tester.tap(find.byTooltip('Select comics'));
    await tester.pumpAndSettle();
    await tester.tap(_tile('seed-0'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 1 comics'), findsOneWidget);
    await tester.pumpWidget(fixture.host(folder: 'A'));
    await _settle(tester);
    expect(find.text('Selected 1 comics'), findsNothing);
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    expect(find.text('Selected 1 comics'), findsNothing);
    expect(
      tester.widget<SliverGridComics>(find.byType(SliverGridComics)).selections,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press range selection skips hidden comics', (tester) async {
    final fixture = await _prepare(tester, 3);
    appdata.settings[KeywordPreferences.comics.key] = <String>['Existing 1'];
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    await tester.longPress(_tile('seed-0'));
    await tester.pumpAndSettle();
    await tester.longPress(_tile('seed-2'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 2 comics'), findsOneWidget);
    expect(
      tester
          .widget<SliverGridComics>(find.byType(SliverGridComics))
          .selections!
          .keys
          .map((comic) => comic.id),
      unorderedEquals(['seed-0', 'seed-2']),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading-status exclusions and active search constrain selection',
    (tester) async {
      final fixture = await _prepare(tester, 3);
      appdata.implicitData['local_favorites_read_filter'] = 'Completed';
      await tester.pumpWidget(fixture.host());
      await _settle(tester);
      expect(_tile('seed-0'), findsNothing);
      expect(
        find.text('Hidden by reading-status filter: 3 comics'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.checklist_rounded),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(_tile('seed-0'), findsOneWidget);
      expect(
        find.text('Hidden by reading-status filter: 3 comics'),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'Existing 1');
      await tester.pumpAndSettle();
      await tester.longPress(_tile('seed-1'));
      await tester.pumpAndSettle();
      await _chooseAction(tester, 'Select All');
      expect(find.text('Selected 1 comics'), findsOneWidget);
      expect(
        tester
            .widget<SliverGridComics>(find.byType(SliverGridComics))
            .selections!
            .keys
            .single
            .id,
        'seed-1',
      );
      await _chooseAction(tester, 'Invert Selection');
      expect(find.text('Selected 0 comics'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final count in [0, 499, 500]) {
    for (final query in ['', 'New']) {
      for (final covered in [false, true]) {
        testWidgets(
          'search follows additions and deletions: count=$count query=$query covered=$covered',
          (tester) async {
            final fixture = await _prepare(tester, count);
            await tester.pumpWidget(fixture.host());
            await _settle(tester);
            await tester.tap(find.byTooltip('Search'));
            await tester.pumpAndSettle();
            if (query.isNotEmpty) {
              await tester.enterText(find.byType(TextField), query);
            }
            await tester.pumpAndSettle();
            if (covered) {
              unawaited(
                fixture.navigator.currentState!.push<void>(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(body: Text('Details')),
                  ),
                ),
              );
              await tester.pumpAndSettle();
            }
            await tester.runAsync(
              () => fixture.manager.addComic(
                'B',
                _comic('new', 'New matching comic'),
              ),
            );
            await _settle(tester);
            if (covered) {
              fixture.navigator.currentState!.pop();
              await tester.pumpAndSettle();
            }
            expect(_tile('new'), findsOneWidget);
            expect(
              tester
                  .widget<EditableText>(find.byType(EditableText))
                  .controller
                  .text,
              query,
            );
            await tester.runAsync(
              () => fixture.manager.deleteComicWithId(
                'B',
                'new',
                const ComicType(17),
              ),
            );
            await _settle(tester);
            expect(_tile('new'), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('switching folders replaces the active search results', (
    tester,
  ) async {
    final fixture = await _prepare(tester, 500);
    await tester.runAsync(() async {
      await fixture.manager.addComic('B', _comic('from-b', 'New comic B'));
      await fixture.manager.addComic('A', _comic('from-a', 'New comic A'));
    });
    await tester.pumpWidget(fixture.host());
    await _settle(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New');
    await tester.pumpAndSettle();
    expect(_tile('from-b'), findsOneWidget);
    await tester.pumpWidget(fixture.host(folder: 'A'));
    await _settle(tester);
    expect(_tile('from-a'), findsOneWidget);
    expect(_tile('from-b'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
