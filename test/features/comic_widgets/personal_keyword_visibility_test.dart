import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';

const books = [
  Comic(
    'Hidden book',
    '',
    'hidden',
    null,
    null,
    '',
    'webdav_library',
    null,
    null,
  ),
  Comic(
    'Visible book',
    '',
    'visible',
    null,
    null,
    '',
    'webdav_library',
    null,
    null,
  ),
];

void main() {
  late Map<String, dynamic> previous;
  const keys = [
    'blockedWords',
    'blockedWordRules',
    'filterPersonalComicLists',
    'comicDisplayMode',
    'comicListDisplayMode',
    'showFavoriteStatusOnTile',
    'showHistoryStatusOnTile',
    'showUpdateStatusOnTile',
  ];
  setUp(() {
    previous = {for (final key in keys) key: appdata.settings[key]};
    appdata.settings['blockedWords'] = ['Hidden'];
    appdata.settings['blockedWordRules'] = <String, String>{};
    appdata.settings['filterPersonalComicLists'] = false;
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
  });
  tearDown(() {
    for (final entry in previous.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  });

  testWidgets(
    'personal lists retain comics and react to scope setting without changing data',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverGridComics(
                  comics: books,
                  keywordScope: ComicKeywordScope.personal,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
      expect(find.text('Visible book'), findsOneWidget);
      expect(find.text('Hidden by keyword filters: 1 comics'), findsNothing);
      appdata.settings['filterPersonalComicLists'] = true;
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsNothing);
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      appdata.settings['filterPersonalComicLists'] = false;
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
      expect(books.map((book) => book.id), ['hidden', 'visible']);
      expect(appdata.settings['blockedWords'], ['Hidden']);
    },
  );

  testWidgets(
    'changing the same grid from personal to discovery applies the rules',
    (tester) async {
      Future<void> mount(ComicKeywordScope scope) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverGridComics(
                  key: const ValueKey('same-grid'),
                  comics: books,
                  keywordScope: scope,
                ),
              ],
            ),
          ),
        ),
      );
      await mount(ComicKeywordScope.personal);
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
      await mount(ComicKeywordScope.discovery);
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsNothing);
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      await mount(ComicKeywordScope.personal);
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
    },
  );

  for (final mode in ['paging', 'continuous']) {
    testWidgets('personal paginated list propagates filtering scope: $mode', (
      tester,
    ) async {
      appdata.settings['comicListDisplayMode'] = mode;
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicList(
              keywordScope: ComicKeywordScope.personal,
              loadPage: (_) async {
                loads++;
                return Res(books, subData: 1);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
      appdata.settings['filterPersonalComicLists'] = true;
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsNothing);
      expect(find.text('Visible book'), findsOneWidget);
      expect(loads, 1);
      appdata.settings['filterPersonalComicLists'] = false;
      await tester.pumpAndSettle();
      expect(find.text('Hidden book'), findsOneWidget);
      expect(loads, 1);
    });
  }
}
