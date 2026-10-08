import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test('nonfinite favorite gallery columns fall back to automatic layout', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(FavoritePreferences.galleryColumns.normalize(value), 0);
    }
  });
  testWidgets(
    'gallery menu tolerates nonfinite columns without changing storage',
    (tester) async {
      final mode = appdata.settings[FavoritePreferences.displayMode.key];
      final columns = appdata.settings[FavoritePreferences.galleryColumns.key];
      addTearDown(() {
        appdata.settings[FavoritePreferences.displayMode.key] = mode;
        appdata.settings[FavoritePreferences.galleryColumns.key] = columns;
      });
      appdata.settings[FavoritePreferences.displayMode.key] = 'gallery';
      appdata.settings[FavoritePreferences.galleryColumns.key] =
          double.infinity;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: FavoriteDisplayButton())),
        ),
      );
      await tester.tap(find.byTooltip('Favorite display mode'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Auto'), findsOneWidget);
      expect(
        appdata.settings[FavoritePreferences.galleryColumns.key],
        double.infinity,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('favorite gallery columns are normalized', () {
    expect(FavoritePreferences.galleryColumns.normalize(null), 0);
    expect(FavoritePreferences.galleryColumns.normalize('4'), 0);
    expect(FavoritePreferences.galleryColumns.normalize(0), 0);
    expect(FavoritePreferences.galleryColumns.normalize(1), 2);
    expect(FavoritePreferences.galleryColumns.normalize(4), 4);
    expect(FavoritePreferences.galleryColumns.normalize(9), 6);
  });

  testWidgets('favorite display settings switch list and gallery layouts', (
    tester,
  ) async {
    const comic = Comic(
      'Cat Eye',
      '',
      'cat-eye',
      null,
      null,
      '',
      'test-source',
      null,
      null,
    );
    final oldFavoriteDisplay =
        appdata.settings[FavoritePreferences.displayMode.key];
    final oldGalleryColumns =
        appdata.settings[FavoritePreferences.galleryColumns.key];
    final oldDisplayMode = appdata.settings['comicDisplayMode'];
    final oldBlockedWords = appdata.settings['blockedWords'];
    final oldFavoriteStatus = appdata.settings['showFavoriteStatusOnTile'];
    final oldHistoryStatus = appdata.settings['showHistoryStatusOnTile'];
    final oldUpdateStatus = appdata.settings['showUpdateStatusOnTile'];

    appdata.settings[FavoritePreferences.displayMode.key] = 'gallery';
    appdata.settings[FavoritePreferences.galleryColumns.key] = 4;
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
    configureComicWidgets(
      favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
        isGallery:
            (GlobalPreferenceStore(
              appdata.settings,
            ).read(FavoritePreferences.displayMode) ==
            'gallery'),
        galleryColumns: GlobalPreferenceStore(
          appdata.settings,
        ).read(FavoritePreferences.galleryColumns),
      ),
    );
    addTearDown(configureComicWidgets);
    addTearDown(() {
      appdata.settings[FavoritePreferences.displayMode.key] =
          oldFavoriteDisplay;
      appdata.settings[FavoritePreferences.galleryColumns.key] =
          oldGalleryColumns;
      appdata.settings['comicDisplayMode'] = oldDisplayMode;
      appdata.settings['blockedWords'] = oldBlockedWords;
      appdata.settings['showFavoriteStatusOnTile'] = oldFavoriteStatus;
      appdata.settings['showHistoryStatusOnTile'] = oldHistoryStatus;
      appdata.settings['showUpdateStatusOnTile'] = oldUpdateStatus;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverGridComics(
                comics: [comic],
                useFavoriteDisplaySettings: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    var tile = tester.widget<ComicTile>(find.byType(ComicTile));
    var grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    var delegate = grid.gridDelegate as SliverGridDelegateWithComics;
    expect(tile.displayMode, ComicTileDisplayMode.gallery);
    expect(delegate.galleryColumns, 4);
    expect(delegate.forceDetailed, isFalse);

    appdata.settings[FavoritePreferences.displayMode.key] = 'list';
    await tester.pump();

    tile = tester.widget<ComicTile>(find.byType(ComicTile));
    grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    delegate = grid.gridDelegate as SliverGridDelegateWithComics;
    expect(tile.displayMode, ComicTileDisplayMode.detailed);
    expect(delegate.galleryColumns, isNull);
    expect(delegate.forceDetailed, isTrue);
  });
}
