import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/image.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_widgets/comic_list.dart';
import 'package:venera_next/features/comic_widgets/comic_tile.dart';
import 'package:venera_next/foundation/appdata.dart';

import '../../support/ui_regression_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadUiRegressionFonts);
  const description = 'Volume Two - Chapter 184 - Page 23';
  final comic = Comic.fromJson({
    'title': 'Sample comic title',
    'cover': '',
    'id': 'book',
    'subtitle': 'Sample author',
    'tags': ['topic:First', 'topic:Second'],
    'description': '2026-11-10 | Sample source',
    'language': 'en',
    'stars': 4.5,
  }, 'missing-source');

  setUp(() {
    final language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    addTearDown(() => appdata.settings['language'] = language);
  });
  tearDown(configureComicWidgets);

  for (final scenario in [
    (size: const Size(375, 667), scale: 1.0, dark: false),
    (size: const Size(375, 667), scale: 3.2, dark: true),
    (size: const Size(667, 375), scale: 2.0, dark: true),
    (size: const Size(1024, 768), scale: 1.0, dark: false),
  ]) {
    for (final compact in [false, true]) {
      testWidgets(
        'detailed status stays on its cover at $scenario, compact=$compact',
        (tester) async {
          configureComicWidgets(
            favoriteDisplayStateResolver: () =>
                const ComicFavoriteDisplayState(),
            tileStateResolver: (_) => ComicTileState(
              isFavorite: true,
              hasNewUpdate: true,
              historyPage: 23,
              historyDescription: description,
              historyCompactDescription: compact ? 'Ch. 184\nP. 23' : null,
            ),
            tileImageProviderResolver: (_) =>
                const AssetImage('assets/app_icon.png'),
          );
          tester.view.physicalSize = scenario.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  brightness: scenario.dark
                      ? Brightness.dark
                      : Brightness.light,
                  fontFamily: uiRegressionFont,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: SafeArea(
                    child: CustomScrollView(
                      slivers: [
                        SliverGridComics(
                          comics: [comic],
                          useFavoriteDisplaySettings: true,
                          showHiddenCount: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final cover = tester.getRect(find.byType(AnimatedImage));
          final title = tester.getRect(find.text(comic.title));
          final progress = tester.getRect(find.byTooltip(description));
          expect(progress.overlaps(title), isFalse);
          final footer = tester.getRect(find.text(comic.description));
          expect(footer.top, greaterThanOrEqualTo(title.bottom));
          expect(footer.bottom, lessThanOrEqualTo(cover.bottom + 0.01));
          for (final badge in [
            progress,
            tester.getRect(find.byIcon(Icons.bookmark_rounded)),
            tester.getRect(find.byIcon(Icons.update)),
          ]) {
            expect(badge.left, greaterThanOrEqualTo(cover.left));
            expect(badge.right, lessThanOrEqualTo(cover.right + 0.01));
            expect(badge.bottom, lessThanOrEqualTo(cover.bottom));
          }
          final semantics = tester.ensureSemantics();
          await tester.pump();
          expect(
            find.bySemanticsLabel(RegExp(RegExp.escape(description))),
            findsWidgets,
          );
          semantics.dispose();
          await captureUiRegression(
            tester,
            boundary,
            'progress-${scenario.size.width.toInt()}-${scenario.scale}-$compact',
          );
        },
      );
    }
  }
}
