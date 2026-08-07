import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites_display.dart';
import 'package:venera_next/foundation/appdata.dart';

void main() {
  test('favorite gallery columns are normalized', () {
    expect(normalizeFavoriteGalleryColumns(null), 0);
    expect(normalizeFavoriteGalleryColumns('4'), 0);
    expect(normalizeFavoriteGalleryColumns(0), 0);
    expect(normalizeFavoriteGalleryColumns(1), 2);
    expect(normalizeFavoriteGalleryColumns(4), 4);
    expect(normalizeFavoriteGalleryColumns(9), 6);
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
    final oldFavoriteDisplay = appdata.settings[favoriteDisplayModeKey];
    final oldGalleryColumns = appdata.settings[favoriteGalleryColumnsKey];
    final oldDisplayMode = appdata.settings['comicDisplayMode'];
    final oldBlockedWords = appdata.settings['blockedWords'];
    final oldFavoriteStatus = appdata.settings['showFavoriteStatusOnTile'];
    final oldHistoryStatus = appdata.settings['showHistoryStatusOnTile'];
    final oldUpdateStatus = appdata.settings['showUpdateStatusOnTile'];

    appdata.settings[favoriteDisplayModeKey] = favoriteDisplayGallery;
    appdata.settings[favoriteGalleryColumnsKey] = 4;
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
    addTearDown(() {
      appdata.settings[favoriteDisplayModeKey] = oldFavoriteDisplay;
      appdata.settings[favoriteGalleryColumnsKey] = oldGalleryColumns;
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

    appdata.settings[favoriteDisplayModeKey] = favoriteDisplayList;
    await tester.pump();

    tile = tester.widget<ComicTile>(find.byType(ComicTile));
    grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    delegate = grid.gridDelegate as SliverGridDelegateWithComics;
    expect(tile.displayMode, ComicTileDisplayMode.detailed);
    expect(delegate.galleryColumns, isNull);
    expect(delegate.forceDetailed, isTrue);
  });
}
