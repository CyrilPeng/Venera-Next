import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_widgets/comic_list.dart';
import 'package:venera_next/features/comic_widgets/comic_tile.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';

Comic _comic(String title, {List<String>? tags}) =>
    Comic(title, '', title, null, tags, '', 'webdav_library', null, null);

class _ObservedComic extends Comic {
  _ObservedComic()
    : super(
        'Offscreen',
        '',
        'observed',
        null,
        const [],
        '',
        'webdav_library',
        null,
        null,
      );

  int reads = 0;

  @override
  String get title {
    reads++;
    return super.title;
  }
}

void main() {
  testWidgets(
    'layout rebuilds reuse filtering while changed input metadata is refreshed',
    (tester) async {
      appdata.settings['blockedWords'] = <String>['Hidden'];
      final observed = _ObservedComic();
      final comics = <Comic>[
        for (var i = 0; i < 100; i++) _comic('Visible $i'),
        observed,
      ];
      Widget build() => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [SliverGridComics(comics: comics)]),
        ),
      );
      await tester.pumpWidget(build());
      final reads = observed.reads;
      expect(reads, greaterThan(0));
      await tester.pumpWidget(build());
      await tester.pump();
      expect(observed.reads, reads);
      comics[comics.length - 1] = Comic(
        'Hidden',
        '',
        observed.id,
        null,
        const [],
        '',
        observed.sourceKey,
        null,
        null,
      );
      await tester.pumpWidget(build());
      await tester.pump();
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      comics.removeLast();
      await tester.pumpWidget(build());
      await tester.pump();
      expect(find.text('Hidden by keyword filters: 1 comics'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'duplicate source entries retain distinct hero identities after refresh',
    (tester) async {
      final comic = _comic('Duplicate');
      Widget build() => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverGridComics(comics: [comic, comic]),
            ],
          ),
        ),
      );
      await tester.pumpWidget(build());
      final before = tester
          .widgetList<ComicTile>(find.byType(ComicTile))
          .map((tile) => tile.heroID)
          .toList();
      expect(before.toSet(), hasLength(2));
      await tester.pumpWidget(build());
      final after = tester
          .widgetList<ComicTile>(find.byType(ComicTile))
          .map((tile) => tile.heroID)
          .toList();
      expect(after, before);
      expect(tester.takeException(), isNull);
    },
  );

  for (final favorites in [false, true]) {
    testWidgets(
      'keyword changes refresh mounted grids and keep hero identities: favorites=$favorites',
      (tester) async {
        final settings = Map<String, dynamic>.from(
          appdata.toJson()['settings'] as Map,
        );
        final changes = ChangeNotifier();
        configureComicWidgets(
          addStateListener: changes.addListener,
          removeStateListener: changes.removeListener,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          configureComicWidgets();
          changes.dispose();
          settings.forEach((key, value) => appdata.settings[key] = value);
        });
        appdata.settings['language'] = 'en-US';
        appdata.settings['blockedWords'] = <String>['Hidden'];
        final comics = [_comic('Visible'), _comic('Hidden')];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverGridComics(
                    comics: comics,
                    showHiddenCount: true,
                    useFavoriteDisplaySettings: favorites,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final visibleHero = tester
            .widget<ComicTile>(find.byType(ComicTile))
            .heroID;
        expect(
          find.text('Hidden by keyword filters: 1 comics'),
          findsOneWidget,
        );
        appdata.settings['blockedWords'] = <String>[];
        await tester.pumpAndSettle();
        expect(find.byType(ComicTile), findsNWidgets(2));
        expect(
          tester.widget<ComicTile>(find.byType(ComicTile).first).heroID,
          visibleHero,
        );
        expect(find.text('Hidden by keyword filters: 1 comics'), findsNothing);
        appdata.settings['blockedWords'] = <String>['Hidden'];
        changes.notifyListeners();
        await tester.pumpAndSettle();
        appdata.settings['blockedWords'] = <String>[];
        changes.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(ComicTile), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  setUp(() {
    final previous = {
      for (final key in [
        'comicListDisplayMode',
        'comicDisplayMode',
        'blockedWords',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['blockedWords'] = <String>[];
    addTearDown(() {
      previous.forEach((key, value) => appdata.settings[key] = value);
    });
  });

  for (final cursor in [false, true]) {
    testWidgets(
      'refresh keeps its own result when an old load finishes: cursor=$cursor',
      (tester) async {
        final key = GlobalKey<ComicListState>();
        final calls = <Completer<Res<List<Comic>>>>[];
        Future<Res<List<Comic>>> load() {
          final result = Completer<Res<List<Comic>>>();
          calls.add(result);
          return result.future;
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ComicList(
                key: key,
                loadPage: cursor ? null : (_) => load(),
                loadNext: cursor ? (_) => load() : null,
              ),
            ),
          ),
        );
        expect(calls, hasLength(1));
        key.currentState!.refresh();
        await tester.pump();
        expect(calls, hasLength(2));
        calls.last.complete(
          Res([_comic('Current')], subData: cursor ? null : 1),
        );
        await tester.pump();
        await tester.pump();
        calls.first.complete(
          Res([_comic('Obsolete')], subData: cursor ? null : 1),
        );
        await tester.pumpAndSettle();
        expect(find.text('Current'), findsOneWidget);
        expect(find.text('Obsolete'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a remounted page does not inherit its predecessor pending request',
    (tester) async {
      final bucket = PageStorageBucket();
      final calls = <Completer<Res<List<Comic>>>>[];
      Widget page(bool show) => MaterialApp(
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: show
                ? ComicList(
                    key: const PageStorageKey('comics'),
                    enablePageStorage: true,
                    loadPage: (page) {
                      if (page == 1) {
                        return Future.value(Res([_comic('First')], subData: 2));
                      }
                      final result = Completer<Res<List<Comic>>>();
                      calls.add(result);
                      return result.future;
                    },
                  )
                : const SizedBox(),
          ),
        ),
      );
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Next'));
      await tester.pump();
      expect(calls, hasLength(1));
      await tester.pumpWidget(page(false));
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Next'));
      await tester.pump();
      expect(calls, hasLength(2));
      calls.last.complete(Res([_comic('Second')], subData: 2));
      await tester.pumpAndSettle();
      calls.first.completeError(StateError('late retired request'));
      await tester.pumpAndSettle();
      expect(find.text('Second'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detailed cards render immutable tags without editing source data',
    (tester) async {
      final tags = List<String>.unmodifiable(['', 'tag\nname', 'genre:one']);
      final comic = _comic('Immutable tags', tags: tags);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 240,
                child: ComicTile(
                  comic: comic,
                  displayMode: ComicTileDisplayMode.detailed,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tags, ['', 'tag\nname', 'genre:one']);
      expect(find.text('tag name'), findsOneWidget);
    },
  );
}
