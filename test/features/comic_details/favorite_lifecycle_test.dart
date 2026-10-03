import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/favorite.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/cache.dart';

void main() {
  setUp(() {
    final previous = appdata.settings['autoCloseFavoritePanel'];
    appdata.settings['autoCloseFavoritePanel'] = false;
    addTearDown(() {
      appdata.settings['autoCloseFavoritePanel'] = previous;
      NetworkCacheManager().clear();
    });
  });

  for (final multi in [false, true]) {
    testWidgets(
      'multi=$multi pending mutation deduplicates and survives disposal',
      (tester) async {
        final pending = Completer<Res<bool>>();
        var calls = 0;
        var notifications = 0;
        final data = FavoriteData(
          key: 'test',
          title: 'Favorites',
          multiFolder: multi,
          loadComic: null,
          loadNext: null,
          loadFolders: multi
              ? ([id]) async => const Res({'folder': 'Folder'})
              : null,
          addOrDelFavorite: (comic, folder, adding, fav) {
            calls++;
            return pending.future;
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NetworkFavoriteSection(
                cid: 'book',
                favoriteData: data,
                isFavorite: false,
                onFavorite: (_) => notifications++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.tap(find.text('Add'));
        expect(calls, 1);
        final uri = Uri.parse('https://example.test/favorites');
        NetworkCacheManager().setCache(
          NetworkCache(
            uri: uri,
            requestHeaders: {},
            responseHeaders: {},
            data: 'old',
            time: DateTime.now(),
            size: 3,
          ),
        );
        await tester.pumpWidget(const SizedBox());
        pending.complete(const Res(true));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(notifications, 0);
        expect(NetworkCacheManager().getCache(uri), isNull);
      },
    );

    testWidgets('multi=$multi thrown mutation resets busy and permits retry', (
      tester,
    ) async {
      var calls = 0;
      final changes = <bool>[];
      final data = FavoriteData(
        key: 'test',
        title: 'Favorites',
        multiFolder: multi,
        loadComic: null,
        loadNext: null,
        loadFolders: multi
            ? ([id]) async => const Res({'folder': 'Folder'})
            : null,
        addOrDelFavorite: (_, folder, adding, fav) {
          if (++calls == 1) throw StateError('offline');
          return Future.value(const Res(true));
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NetworkFavoriteSection(
              cid: 'book',
              favoriteData: data,
              isFavorite: false,
              onFavorite: changes.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(changes, isEmpty);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(changes, [true]);
      expect(find.text('Remove'), findsOneWidget);
    });
  }

  testWidgets(
    'folder failure has retry and late folder exception is contained',
    (tester) async {
      var calls = 0;
      final pending = Completer<Res<Map<String, String>>>();
      final data = FavoriteData(
        key: 'test',
        title: 'Favorites',
        multiFolder: true,
        loadComic: null,
        loadNext: null,
        loadFolders: ([id]) {
          if (++calls == 1) throw StateError('offline');
          return pending.future;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NetworkFavoriteSection(
              cid: 'book',
              favoriteData: data,
              isFavorite: false,
              onFavorite: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('late'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(calls, 2);
    },
  );
}
