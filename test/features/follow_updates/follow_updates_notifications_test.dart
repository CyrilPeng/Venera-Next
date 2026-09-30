import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/foundation/appdata.dart';

class _Favorites extends Fake implements LocalFavoritesManager {
  int updates = 1;
  @override
  List<String> get folderNames => ['following'];
  @override
  int countUpdates(String folder) => updates;
  @override
  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) =>
      [];
}

void main() {
  testWidgets(
    'all mounted previews refresh and release their domain listener',
    (tester) async {
      final previous = LocalFavoritesManager.cache;
      final folder = appdata.settings['followUpdatesFolder'];
      final favorites = _Favorites();
      LocalFavoritesManager.cache = favorites;
      appdata.settings['followUpdatesFolder'] = 'following';
      addTearDown(() {
        LocalFavoritesManager.cache = previous;
        appdata.settings['followUpdatesFolder'] = folder;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FollowUpdatesWidget(), FollowUpdatesWidget()],
            ),
          ),
        ),
      );
      expect(find.text('1 updates'), findsNWidgets(2));
      favorites.updates = 3;
      notifyFollowUpdatesChanged();
      await tester.pump();
      expect(find.text('3 updates'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      notifyFollowUpdatesChanged();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
