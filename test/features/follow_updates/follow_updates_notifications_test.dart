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
      final runtime = _runtime();
      final replacement = _runtime();
      addTearDown(runtime.dispose);
      addTearDown(replacement.dispose);
      Widget app(FollowUpdatesRuntime owner) => FollowUpdatesScope(
        runtime: owner,
        child: const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [FollowUpdatesWidget(), FollowUpdatesWidget()],
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(runtime));
      expect(find.text('1 updates'), findsNWidgets(2));
      favorites.updates = 3;
      runtime.notifyChanged();
      await tester.pump();
      expect(find.text('3 updates'), findsNWidgets(2));
      await tester.pumpWidget(app(replacement));
      favorites.updates = 5;
      runtime.notifyChanged();
      await tester.pump();
      expect(find.text('3 updates'), findsNWidgets(2));
      replacement.notifyChanged();
      await tester.pump();
      expect(find.text('5 updates'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      replacement.notifyChanged();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

FollowUpdatesRuntime _runtime() => FollowUpdatesRuntime(
  folder: () => null,
  isChecking: () => false,
  waitForDownload: () async {},
  createTask: (_) => throw StateError('Unexpected task'),
  onError: (_, _) {},
  observeChanges: (_) => () {},
);
