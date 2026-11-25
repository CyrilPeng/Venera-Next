import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/components/navigation_bar.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/history/history_summary.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/loading.dart';
import 'package:venera_next/features/reader/reader_session_scope.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/features/reader/progress_bar.dart';
import 'package:venera_next/features/reader/images_host.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/network/request_scope.dart';

import 'support/reader_integration_fixture.dart';

Future<void> _expectOpaqueSurface(WidgetTester tester, GlobalKey key) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (final x in [4, image.width - 5]) {
          for (final y in [4, image.height - 5]) {
            expect(
              pixels.getUint8((y * image.width + x) * 4 + 3),
              255,
              reason: 'The reading surface must cover the previous route.',
            );
          }
        }
      } finally {
        image.dispose();
      }
    });

void main() {
  setUpReaderIntegration();

  for (final previouslyRead in [false, true]) {
    testWidgets(
      'home local cover opens only the root reader and returns without a flight: read=$previouslyRead',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(375, 812));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await ReaderIntegrationFixture.create(tester);
        final history = HistoryManager.create();
        await tester.runAsync(history.init);
        readerFixtureHistoryOwner = history;
        final local = LocalManager().find('book', ComicType.local)!;
        final nestedKey = GlobalKey<NavigatorState>();
        final paneKey = GlobalKey<NaviPaneState>();
        final observer = NaviObserver();
        final previousMain = appNavigation.mainNavigatorKey;
        appNavigation.mainNavigatorKey = nestedKey;
        configureComicWidgets(
          tileImageProviderResolver: (_) => LocalComicImageProvider(local),
        );
        try {
          if (previouslyRead) {
            await tester.runAsync(
              () => history.addHistory(readerResumeHistory(page: 2)),
            );
          }
          await tester.pumpWidget(
            readerFixtureLibraryView(
              ReaderSessionScope(
                onClosed: () => fixture.notifications++,
                child: MaterialApp(
                  navigatorKey: appNavigation.rootNavigatorKey,
                  builder: (_, child) => OverlayWidget(child!),
                  home: NaviPane(
                    key: paneKey,
                    paneItems: [
                      PaneItemEntry(
                        label: 'Home',
                        icon: Icons.home,
                        activeIcon: Icons.home,
                      ),
                      PaneItemEntry(
                        label: 'Other',
                        icon: Icons.book,
                        activeIcon: Icons.book,
                      ),
                    ],
                    paneActions: const [],
                    pageBuilder: (page) => page == 0
                        ? CustomScrollView(
                            slivers: [
                              HistorySummary(
                                manager: history,
                                favoriteChanges: null,
                              ),
                              const LocalComicsSummary(),
                            ],
                          )
                        : const Material(child: Text('Other page')),
                    navigatorKey: nestedKey,
                    observer: observer,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final covers = find.byType(SimpleComicTile);
          final tags = tester
              .widgetList<Hero>(find.byType(Hero))
              .map((hero) => hero.tag)
              .toList();
          expect(tags.toSet(), hasLength(tags.length));
          final localCover = find.descendant(
            of: find.byType(LocalComicsSummary),
            matching: covers,
          );
          await tester.tap(localCover);
          expect(
            observer.routes,
            hasLength(1),
            reason:
                'Imported local covers must not push a transient detail route.',
          );
          await pumpReaderUntil(tester, () {
            if (find.byType(Reader).evaluate().isEmpty) return false;
            final reader = tester.state<ReaderState>(find.byType(Reader));
            return !reader.isLoading &&
                (reader.imageViewController as AutoReadingViewport?)
                        ?.autoReadingReady ==
                    true;
          });
          final reader = tester.state<ReaderState>(find.byType(Reader));
          expect(reader.page, previouslyRead ? 2 : 1);
          final exit = reader.requestExit();
          await pumpReaderUntil(
            tester,
            () => !appNavigation.rootNavigatorKey.currentState!.canPop(),
          );
          await exit;
          await tester.pumpAndSettle();
          expect(observer.routes, hasLength(1));
          expect(find.byType(Reader), findsNothing);
          expect(
            history.find('book', ComicType.local)?.page,
            previouslyRead ? 2 : 1,
          );
          paneKey.currentState!.updatePage(1);
          await tester.pumpAndSettle();
          expect(find.byType(SimpleComicTile), findsNothing);
          expect(find.byType(Hero, skipOffstage: false), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          appNavigation.mainNavigatorKey = previousMain;
          configureComicWidgets();
          history.close();
          history.dispose();
          await fixture.dispose(tester);
        }
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('direct reader covers its first loading frame: $brightness', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final release = Completer<void>();
      final holding = AppDataOperations.instance.run(() => release.future);
      try {
        await fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          withScaffold: false,
          firstFrameOnly: true,
          brightness: brightness,
        );
        expect(fixture.readerKey.currentState!.isLoading, isTrue);
        await _expectOpaqueSurface(tester, fixture.surfaceKey);
        release.complete();
        await holding;
        await pumpReaderUntil(
          tester,
          () =>
              !fixture.readerKey.currentState!.isLoading &&
              (fixture.readerKey.currentState!.imageViewController
                          as AutoReadingViewport?)
                      ?.autoReadingReady ==
                  true,
        );
        await _expectOpaqueSurface(tester, fixture.surfaceKey);
      } finally {
        if (!release.isCompleted) release.complete();
        await holding;
        await fixture.dispose(tester);
      }
    });

    testWidgets(
      'reader metadata loading and retry retain the surface: $brightness',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final history = HistoryManager();
        await tester.runAsync(history.init);
        var id = 'missing';
        Future<void> mount() => fixture.mount(
          tester,
          pushed: false,
          withWindow: false,
          withScaffold: false,
          firstFrameOnly: true,
          brightness: brightness,
          entryBuilder: () => ReaderSessionScope(
            onClosed: () => fixture.notifications++,
            child: ReaderWithLoading(id: id, sourceKey: 'local'),
          ),
        );
        try {
          await mount();
          await _expectOpaqueSurface(tester, fixture.surfaceKey);
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('comic not found'), findsOneWidget);
          await _expectOpaqueSurface(tester, fixture.surfaceKey);
          id = 'book';
          await mount();
          await _expectOpaqueSurface(tester, fixture.surfaceKey);
          await pumpReaderUntil(tester, () {
            if (find.byType(Reader).evaluate().isEmpty) return false;
            final reader = tester.state<ReaderState>(find.byType(Reader));
            return !reader.isLoading &&
                (reader.imageViewController as AutoReadingViewport?)
                        ?.autoReadingReady ==
                    true;
          });
          await _expectOpaqueSurface(tester, fixture.surfaceKey);
          expect(tester.takeException(), isNull);
        } finally {
          history.close();
          await fixture.dispose(tester);
        }
      },
    );
  }

  for (final mode in [
    ReaderMode.galleryLeftToRight,
    ReaderMode.continuousTopToBottom,
    ReaderMode.waterfallTopToBottom,
  ]) {
    for (final savedPage in [2, 1001]) {
      for (final group in [null, 1]) {
        testWidgets(
          'chapterless history resumes page $savedPage with group $group in ${mode.key}',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(375, 667));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final imageCount = savedPage == 1001 ? 1200 : 3;
            final fixture = await ReaderIntegrationFixture.create(
              tester,
              imageCount: imageCount,
            );
            final saved = readerResumeHistory(
              page: savedPage,
              maxPage: imageCount,
            );
            final read = savedPage == 2 && group == null && !mode.isGallery
                ? ReaderLocalReadGate(
                    File('${fixture.directory.path}/comics/book/one/2.png'),
                  )
                : null;
            final previousIO = IOOverrides.current;
            try {
              if (read != null) IOOverrides.global = read;
              appdata.settings['readerMode'] = mode.key;
              await fixture.mount(
                tester,
                pushed: false,
                waitForImage: read == null,
                chapters: null,
                savedHistory: saved,
                initialChapter: saved.ep,
                initialPage: saved.page,
                initialChapterGroup: group,
              );
              final reader = fixture.readerKey.currentState!;
              if (read != null) {
                final viewport =
                    reader.imageViewController! as ContinuousModeState;
                await pumpReaderUntil(
                  tester,
                  () =>
                      read.reads > 0 &&
                      viewport.imageStates.whereType<ComicImageState>().any(
                        (image) =>
                            image.visibleInReader &&
                            image.readyForAutoReading &&
                            (image.widget.image as ReaderDisplayImageProvider)
                                    .image
                                    .page ==
                                3,
                      ),
                );
                expect(reader.page, savedPage);
                expect(saved.page, savedPage);
                reader.toPage(3, animated: false);
                await tester.pump();
                expect(reader.page, 3);
                reader.toPage(savedPage, animated: false);
                await tester.pump();
                expect(reader.page, savedPage);
                await tester.drag(
                  find.byType(ReaderContinuousView),
                  const Offset(0, -400),
                );
                await tester.pump(const Duration(milliseconds: 400));
                expect(reader.page, 3);
                reader.toPage(savedPage, animated: false);
                await tester.pump();
                expect(reader.page, savedPage);
                read.release();
                await pumpReaderUntil(tester, () => viewport.autoReadingReady);
              }
              expect(reader.chapter, 1);
              expect(reader.page, savedPage);
              expect(reader.history, same(saved));
              expect(saved.page, savedPage);
              expect(saved.maxPage, imageCount);
              expect(saved.group, isNull);
              expect(tester.takeException(), isNull);
            } finally {
              read?.release();
              IOOverrides.global = previousIO;
              await fixture.dispose(tester);
            }
            expect(fixture.history.progress, isNotEmpty);
            expect(fixture.history.progress.last.page, savedPage);
          },
        );
      }
    }
  }

  testWidgets('flat chapter history ignores obsolete group coordinates', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final saved = readerResumeHistory(chapter: 2, page: 2, group: 2);
    try {
      await fixture.mount(
        tester,
        pushed: false,
        chapters: const ComicChapters({
          'previous': 'Previous',
          'one': 'Current',
        }),
        savedHistory: saved,
        initialChapter: saved.ep,
        initialPage: saved.page,
        initialChapterGroup: saved.group,
      );
      final reader = fixture.readerKey.currentState!;
      expect(reader.chapter, 2);
      expect(reader.eid, 'one');
      expect(reader.page, 2);
      expect(saved.ep, 2);
      expect(saved.page, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final group in [null, 1, 2]) {
    testWidgets(
      'grouped chapter history resumes coordinates with group $group',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final saved = readerResumeHistory(
          chapter: group == null ? 2 : 1,
          page: 2,
          group: group,
        );
        try {
          await fixture.mount(
            tester,
            pushed: false,
            chapters: const ComicChapters.grouped({
              'First volume': {'one': 'First chapter'},
              'Second volume': {'one': 'Second chapter'},
            }),
            savedHistory: saved,
            initialChapter: saved.ep,
            initialPage: saved.page,
            initialChapterGroup: saved.group,
          );
          final reader = fixture.readerKey.currentState!;
          expect(reader.chapter, group == 1 ? 1 : 2);
          expect(reader.eid, 'one');
          expect(reader.page, 2);
          expect(saved.ep, 1);
          expect(saved.group, group == 1 ? 1 : 2);
          expect(saved.page, 2);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets('captured waterfall chapter metadata retains its original map', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final chapters = {'one': 'Original title', 'two': 'Second title'};
    try {
      appdata.settings['readerMode'] = ReaderMode.waterfallTopToBottom.key;
      await fixture.mount(
        tester,
        pushed: false,
        chapters: ComicChapters(chapters),
      );
      final view = tester.widget<ReaderContinuousView>(
        find.byType(ReaderContinuousView),
      );
      chapters.remove('one');
      chapters['one'] = 'Changed title';
      expect(view.chapterId(1), 'one');
      expect(view.chapterTitle(1), 'Original title');
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final detached in [false, true]) {
    testWidgets(
      'captured waterfall load rejects retired target; detached=$detached',
      (tester) async {
        final fixture = await ReaderIntegrationFixture.create(tester);
        final chapters = {'one': 'Original title'};
        final scope = RequestScope();
        try {
          appdata.settings['readerMode'] = ReaderMode.waterfallTopToBottom.key;
          await fixture.mount(
            tester,
            pushed: false,
            chapters: ComicChapters(chapters),
          );
          final view = tester.widget<ReaderContinuousView>(
            find.byType(ReaderContinuousView),
          );
          if (detached) {
            await tester.pumpWidget(const SizedBox());
          } else {
            chapters.remove('one');
            chapters['replacement'] = 'Changed chapter';
          }
          await tester.runAsync(
            () => expectLater(
              view.loadChapter(1, scope),
              throwsA(isA<RequestCancelled>()),
            ),
          );
        } finally {
          scope.dispose();
          await fixture.dispose(tester);
        }
      },
    );
  }

  testWidgets('old progress callbacks cannot navigate a replacement chapter', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(tester, pushed: false);
      final reader = fixture.readerKey.currentState!;
      final progress = tester.widget<ReaderBottomBar>(
        find.byType(ReaderBottomBar),
      );
      reader.controller.restoreChapter(2);
      reader.controller.restorePage(1);
      progress.onPageChanged(2);
      expect(reader.page, 1);
      progress.onPrevious();
      expect(reader.chapter, 2);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('old progress callbacks are harmless after reader removal', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(tester, pushed: false);
      final progress = tester.widget<ReaderBottomBar>(
        find.byType(ReaderBottomBar),
      );
      await tester.pumpWidget(const SizedBox());
      progress.onPageChanged(2);
      progress.onNext();
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'shell page reports update input without rebuilding image content',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        final content = tester.widget<ReaderImagesHost>(
          find.byType(ReaderImagesHost),
        );
        final before = tester.widget<ReaderBottomBar>(
          find.byType(ReaderBottomBar),
        );
        reader.setPage(2);
        reader.updateShell();
        await tester.pump();
        final after = tester.widget<ReaderBottomBar>(
          find.byType(ReaderBottomBar),
        );
        expect(after.page, 2);
        expect(after.label, 'E1 : P2');
        expect(after.progressIdentity, before.progressIdentity);
        expect(
          identical(
            tester.widget<ReaderImagesHost>(find.byType(ReaderImagesHost)),
            content,
          ),
          isTrue,
        );
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('progress retires changed mode, layout, metadata and viewport', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final chapterMap = {'one': 'First', 'two': 'Second'};
    try {
      await fixture.mount(
        tester,
        pushed: false,
        chapters: ComicChapters(chapterMap),
      );
      final reader = fixture.readerKey.currentState!;
      var request = reader.createProgressRequest();
      reader.mode = ReaderMode.galleryRightToLeft;
      expect(request.selectPage(2), isFalse);
      reader.mode = ReaderMode.galleryLeftToRight;
      request = reader.createProgressRequest();
      chapterMap['one'] = 'Renamed';
      expect(request.selectPage(2), isFalse);
      expect(reader.createProgressRequest().identity, isNot(request.identity));
      request = reader.createProgressRequest();
      appdata.settings['readerScreenPicNumberForLandscape'] = 2;
      expect(request.selectPage(2), isFalse);
      appdata.settings['readerScreenPicNumberForLandscape'] = 1;
      request = reader.createProgressRequest();
      final viewport = reader.imageViewController!;
      reader.viewportBinding.clear();
      expect(request.selectPage(2), isFalse);
      reader.viewportBinding.update(viewport, true);
      expect(reader.page, 1);
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final mode in ReaderMode.values) {
    testWidgets('progress dispatches image endpoints in ${mode.key}', (
      tester,
    ) async {
      // Leave enough horizontal content after page 2 to align its leading edge.
      // The last-page clamp below must not also clamp this intermediate page.
      await tester.binding.setSurfaceSize(const Size(700, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        appdata.settings['readerMode'] = mode.key;
        appdata.settings['enablePageAnimation'] = false;
        appdata.settings['enableDoubleTapToZoom'] = false;
        await fixture.mount(
          tester,
          pushed: false,
          chapters: const ComicChapters({'one': 'First'}),
        );
        final reader = fixture.readerKey.currentState!;
        final bounds = tester.getRect(find.byType(ReaderImagesHost));
        final reverse =
            mode == ReaderMode.galleryRightToLeft ||
            mode == ReaderMode.continuousRightToLeft;
        await tester.tapAt(
          mode.isTopToBottom
              ? Offset(bounds.center.dx, bounds.top + bounds.height * 0.85)
              : Offset(
                  bounds.left + bounds.width * (reverse ? 0.15 : 0.85),
                  bounds.center.dy,
                ),
        );
        await tester.pump();
        expect(reader.page, 2);
        final shell = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        shell.openOrClose();
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.byIcon(Icons.first_page))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pump();
        expect(reader.page, 1);
        await tester.sendKeyEvent(
          reverse
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowRight,
        );
        expect(
          reader.page,
          2,
          reason: 'One slider key changes exactly one image page.',
        );
        await tester.pump();
        expect(reader.page, 2);
        shell.openOrClose();
        await tester.pumpAndSettle();
        var progress = tester.widget<ReaderBottomBar>(
          find.byType(ReaderBottomBar),
        );
        progress.onPageChanged(2);
        await tester.pump();
        expect(reader.page, 2);
        progress = tester.widget<ReaderBottomBar>(find.byType(ReaderBottomBar));
        final reversed =
            mode == ReaderMode.galleryRightToLeft ||
            mode == ReaderMode.continuousRightToLeft;
        (reversed ? progress.onPrevious : progress.onNext)();
        expect(reader.page, 3);
        await tester.pump();
        // Equal-area images at the horizontal scroll end retain the requested
        // page instead of reverting to the first visible source image.
        expect(reader.page, 3);
        progress = tester.widget<ReaderBottomBar>(find.byType(ReaderBottomBar));
        (reversed ? progress.onNext : progress.onPrevious)();
        await tester.pump();
        expect(reader.page, 1);
        expect(reader.chapter, 1);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets(
    'progress rejects covered routes and an in-flight content reload',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      try {
        await fixture.mount(tester, pushed: false);
        final reader = fixture.readerKey.currentState!;
        final request = reader.createProgressRequest();
        final navigator = appNavigation.rootNavigatorKey.currentState!;
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Covering page')),
            ),
          ),
        );
        expect(request.selectPage(2), isFalse);
        await tester.pumpAndSettle();
        navigator.pop();
        await tester.pumpAndSettle();
        final loading = reader.controller.beginContentLoad();
        expect(request.selectPage(2), isFalse);
        expect(reader.createProgressRequest().next(), isFalse);
        reader.controller.cancelContentLoad(loading);
        expect(reader.page, 1);
        expect(reader.createProgressRequest().selectPage(2), isTrue);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('floating actions respect all seven modes and group boundaries', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(
        tester,
        pushed: false,
        chapters: const ComicChapters.grouped({
          'First group': {'one': 'First', 'two': 'Second'},
          'Second group': {'three': 'Third'},
        }),
      );
      final reader = fixture.readerKey.currentState!;
      for (final mode in ReaderMode.values) {
        reader.mode = mode;
        reader.controller.restoreChapter(1);
        final first = reader.createChapterNavigationRequest(
          reader.controller.content,
        )!;
        expect(first.canPrevious, false);
        expect(first.canNext, !mode.isGallery && !mode.isWaterfall);
        reader.controller.restoreChapter(2);
        final last = reader.createChapterNavigationRequest(
          reader.controller.content,
        )!;
        expect(first.isCurrent(), false);
        expect(last.canPrevious, !mode.isGallery && !mode.isWaterfall);
        expect(last.canNext, false);
        reader.controller.restoreChapter(3);
        final single = reader.createChapterNavigationRequest(
          reader.controller.content,
        )!;
        expect(single.canPrevious, false);
        expect(single.canNext, false);
      }
    } finally {
      await fixture.dispose(tester);
    }
  });

  for (final mutation in ['order', 'title', 'content']) {
    testWidgets('floating action rejects original $mutation replacement', (
      tester,
    ) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final chapters = {'one': 'First', 'two': 'Second'};
      try {
        appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
        await fixture.mount(
          tester,
          pushed: false,
          chapters: ComicChapters(chapters),
        );
        final reader = fixture.readerKey.currentState!;
        final report = tester
            .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
            .onFloatingButton;
        report(1);
        await tester.pumpAndSettle();
        final action = reader.chapterNavigation.action!;
        if (mutation == 'order') {
          chapters.remove('one');
          chapters['one'] = 'First';
        } else if (mutation == 'title') {
          chapters['one'] = 'Renamed';
        } else {
          reader.controller.replaceChapterImages(reader.images!.toList());
        }
        action.select();
        report(1);
        expect(reader.chapter, 1);
        expect(reader.chapterNavigation.action, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets(
    'floating action cannot navigate during reader save and can resume after failure',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      final saving = Completer<void>();
      try {
        appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
        await fixture.mount(
          tester,
          pushed: true,
          chapters: const ComicChapters({'one': 'First', 'two': 'Second'}),
        );
        final reader = fixture.readerKey.currentState!;
        final report = tester
            .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
            .onFloatingButton;
        report(1);
        await tester.pumpAndSettle();
        final old = reader.chapterNavigation.action!;
        fixture.history.onProgress = (_) => saving.future;
        var exitFinished = false;
        final exiting = reader.requestExit().whenComplete(() {
          exitFinished = true;
        });
        await tester.pump();
        old.select();
        report(1);
        expect(reader.chapter, 1);
        expect(reader.chapterNavigation.action, isNull);
        saving.completeError(StateError('Save rejected'));
        await pumpReaderUntil(tester, () => exitFinished);
        await exiting;
        await tester.pumpAndSettle();
        report(1);
        expect(reader.chapterNavigation.action, isNotNull);
      } finally {
        if (!saving.isCompleted) saving.complete();
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('floating callbacks reject a mounted final host close', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    final host = await readerFixtureHost(() {});
    try {
      appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
      await fixture.mount(
        tester,
        pushed: false,
        withWindow: false,
        registry: host.selections,
        chapters: const ComicChapters({'one': 'First', 'two': 'Second'}),
      );
      final reader = fixture.readerKey.currentState!;
      final report = tester
          .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
          .onFloatingButton;
      report(1);
      await tester.pumpAndSettle();
      final action = reader.chapterNavigation.action!;
      var closed = false;
      final closing = host.close().then((_) => closed = true);
      await pumpReaderUntil(tester, () => closed);
      await closing;
      action.select();
      report(1);
      expect(reader.chapter, 1);
      expect(reader.chapterNavigation.action, isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'old floating viewport cannot reveal navigation after source replacement',
    (tester) async {
      final fixture = await ReaderIntegrationFixture.create(tester);
      var source = ReaderFixtureCommentSource();
      final restore = readerFixtureCommentRegistry(() => source);
      try {
        appdata.settings['readerMode'] = ReaderMode.continuousTopToBottom.key;
        await fixture.mount(
          tester,
          pushed: false,
          chapters: const ComicChapters({'one': 'First', 'two': 'Second'}),
        );
        final old = tester
            .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
            .onFloatingButton;
        source = ReaderFixtureCommentSource();
        fixture.readerKey.currentState!.update();
        await tester.pumpAndSettle();
        old(1);
        await tester.pumpAndSettle();
        expect(
          find.byIcon(Icons.arrow_forward_ios).hitTestable(),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
        restore();
      }
    },
  );

  testWidgets('old gallery ready cannot hide current continuous navigation', (
    tester,
  ) async {
    final fixture = await ReaderIntegrationFixture.create(tester);
    try {
      await fixture.mount(
        tester,
        pushed: false,
        chapters: const ComicChapters({'one': 'First', 'two': 'Second'}),
      );
      final oldReady = tester
          .widget<ReaderGalleryView>(find.byType(ReaderGalleryView))
          .onReady;
      final reader = fixture.readerKey.currentState!;
      reader.mode = ReaderMode.continuousTopToBottom;
      reader.update();
      await tester.pumpAndSettle();
      final current = tester
          .widget<ReaderContinuousView>(find.byType(ReaderContinuousView))
          .onFloatingButton;
      current(1);
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.arrow_forward_ios).hitTestable(),
        findsOneWidget,
      );
      oldReady();
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.arrow_forward_ios).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });
}
