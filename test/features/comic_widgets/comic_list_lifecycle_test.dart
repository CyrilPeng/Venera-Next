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

void main() {
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
