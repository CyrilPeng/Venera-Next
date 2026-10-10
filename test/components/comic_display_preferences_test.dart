import 'dart:convert';

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/layout.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/favorites/favorite_models.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/comic_widgets/comic_list.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/foundation/res.dart';

SliverConstraints _constraints(double width) => SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: 0,
  precedingScrollExtent: 0,
  overlap: 0,
  remainingPaintExtent: 700,
  crossAxisExtent: width,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: 700,
  remainingCacheExtent: 700,
  cacheOrigin: 0,
);

void main() {
  late Map previous;
  setUp(
    () =>
        previous = jsonDecode(jsonEncode(appdata.toJson()['settings'])) as Map,
  );
  tearDown(
    () => previous.forEach((key, value) => appdata.settings[key] = value),
  );

  testWidgets('list renders paging fallback and both continuous spellings', (
    tester,
  ) async {
    for (final raw in [
      null,
      false,
      'invalid',
      'paging',
      'continuous',
      'Continuous',
    ]) {
      appdata.settings['comicListDisplayMode'] = raw;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComicList(
              loadNext: (_) async =>
                  const Res<List<Comic>>([], subData: 'next'),
            ),
          ),
        ),
      );
      // Continuous mode intentionally keeps a next-page loading indicator.
      for (
        var frame = 0;
        frame < 10 && find.byType(SliverGridComics).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump();
      }
      await tester.pump();
      expect(
        find.byType(SliverGridComics, skipOffstage: false),
        findsOneWidget,
        reason:
            'Mode $raw: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
      );
      expect(
        tester
            .widget<SliverGridComics>(
              find.byType(SliverGridComics, skipOffstage: false),
            )
            .comics,
        isEmpty,
        reason: '$raw',
      );
      final continuous = raw == 'continuous' || raw == 'Continuous';
      expect(find.text('Next'), continuous ? findsNothing : findsOneWidget);
      expect(appdata.settings['comicListDisplayMode'], same(raw));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  test(
    'valid display settings keep geometry at narrow, wide and zero width',
    () {
      for (final width in [0.0, 375.0, 812.0]) {
        for (final scale in [0.5, 1.0, 1.013, 1.5]) {
          appdata.settings['comicTileScale'] = scale;
          appdata.settings['comicDisplayMode'] = 'detailed';
          var layout =
              SliverGridDelegateWithComics().getLayout(_constraints(width))
                  as SliverGridRegularTileLayout;
          expect(layout.crossAxisCount, width == 812 ? 2 : 1);
          expect(layout.childMainAxisExtent, 152 * scale);
          expect(layout.childCrossAxisExtent, width / layout.crossAxisCount);
          appdata.settings['comicDisplayMode'] = 'brief';
          layout =
              SliverGridDelegateWithComics().getLayout(_constraints(width))
                  as SliverGridRegularTileLayout;
          expect(layout.childCrossAxisExtent, lessThanOrEqualTo(192 * scale));
          expect(
            layout.childMainAxisExtent,
            layout.childCrossAxisExtent / 0.64,
          );
          expect(layout.crossAxisCount, greaterThanOrEqualTo(1));
          final forced = SliverGridDelegateWithComics(
            forceDetailed: true,
          ).getLayout(_constraints(width)).getGeometryForChildIndex(0);
          expect(forced.mainAxisExtent, 152 * scale);
          final gallery =
              SliverGridDelegateWithComics(
                    galleryColumns: 4,
                  ).getLayout(_constraints(width))
                  as SliverGridRegularTileLayout;
          expect(gallery.crossAxisCount, 4);
          expect(gallery.childMainAxisExtent, width / 4 / 0.64);
        }
      }
    },
  );

  test(
    'invalid tile mode and favorite descriptions share the detailed default',
    () {
      final comic = FavoriteItem(
        id: 'synthetic',
        name: 'Synthetic',
        coverPath: '',
        author: '',
        type: ComicType.local,
        tags: [],
        favoriteTime: DateTime(2026, 10, 8),
      );
      for (final raw in [null, false, 'invalid', [], {}]) {
        appdata.settings['comicDisplayMode'] = raw;
        expect(SliverGridDelegateWithComics().useBriefMode, isFalse);
        expect(comic.description, '2026-10-08 | local');
        expect(appdata.settings['comicDisplayMode'], same(raw));
      }
      appdata.settings['comicDisplayMode'] = 'brief';
      expect(comic.description, 'Unknown | 2026-10-08');
    },
  );

  test(
    'wrong-type stored tile scale falls back without changing stored data',
    () {
      for (final raw in [null, false, 'bad', [], {}]) {
        appdata.settings['comicTileScale'] = raw;
        final delegate = SliverGridDelegateWithComics();
        final geometry = delegate
            .getLayout(_constraints(375))
            .getGeometryForChildIndex(0);
        expect(geometry.mainAxisExtent, 152);
        expect(appdata.settings['comicTileScale'], same(raw));
      }
    },
  );

  test(
    'stored scale outside editor limits cannot create negative tile extents',
    () {
      for (final (raw, bounded) in [(-1, 0.5), (0, 0.5), (99, 1.5)]) {
        appdata.settings['comicTileScale'] = raw;
        appdata.settings['comicDisplayMode'] = 'detailed';
        final delegate = SliverGridDelegateWithComics();
        expect(
          delegate
              .getLayout(_constraints(375))
              .getGeometryForChildIndex(0)
              .mainAxisExtent,
          152 * bounded,
        );
        expect(appdata.settings['comicTileScale'], raw);
      }
    },
  );
}
