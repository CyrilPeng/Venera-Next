import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/reader/platform_effects.dart'
    show ReaderPlatformEffectsScope;
import 'package:venera_next/features/reader/platform_effects_controller.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';

import '../../support/sqlite_test_environment.dart';
import 'support/favorites_read_fixture.dart';

void main() {
  for (final mode in ReaderMode.values) {
    for (final scenario in [
      'ready',
      'failed',
      if (mode.isGallery) 'failedSpread',
    ]) {
      final unavailable = scenario != 'ready';
      testWidgets(
        '${mode.key}: ${unavailable ? 'waits by default and skips $scenario images when enabled' : 'reads content before crossing chapters and stops at the end'}',
        (tester) async {
          final previous =
              jsonDecode(jsonEncode(appdata.toJson()['settings']))
                  as Map<String, dynamic>;
          final previousFavorites = _favoritesOwner;
          final previousHistory = _historyOwner;
          final previousCache = CacheManager.instance;
          CacheManager? cache;
          final previousLogMuted = Log.isMuted;
          final directory = Directory.systemTemp.createTempSync('auto-reader-');
          final key = GlobalKey<_TestReaderState>();
          var screenAwake = false;
          final effects = ReaderPlatformEffectsCoordinator(
            applyOrientation: (_) async {},
            applySystemBars: (_) async {},
            applyScreenAwake: (awake) async => screenAwake = awake,
            onError: (error, _) => fail('$error'),
          );
          try {
            App.dataPath = directory.path;
            App.cachePath = directory.path;
            Log.isMuted = true;
            _favoritesOwner = ReaderFavoritesStub();
            final settings = appdata.settings;
            settings['comicSpecificSettings'] = <String, dynamic>{};
            settings['deviceSpecificSettings'] = <String, dynamic>{};
            settings['autoReaderMode'] = false;
            settings['readerMode'] = mode.key;
            settings['readerScreenPicNumberForLandscape'] =
                scenario == 'failedSpread' ? 2 : 1;
            settings['readerScreenPicNumberForPortrait'] =
                scenario == 'failedSpread' ? 2 : 1;
            settings['autoScrollStyle'] = 'smooth';
            settings['autoScrollSpeed'] = 100;
            settings['autoPageTurningInterval'] = 1;
            settings['autoReadingAcrossChapters'] = true;
            settings['autoReadingSkipUnavailableImages'] = false;
            settings['autoReadingImageWaitSeconds'] = 1;
            settings['autoReadingKeepScreenOn'] = true;
            settings['enableClockAndBatteryInfoInReader'] = false;
            settings['showPageNumberInReader'] = false;
            settings['showImageDimensions'] = !unavailable;
            settings['eInkMode'] = false;
            settings['limitImageWidth'] = false;
            settings['readerSideMargin'] = 20;
            settings['language'] = 'en-US';
            LocalManager.current?.dispose();
            LocalManager(initializeSources: () async {});
            await tester.runAsync(() async {
              cache = CacheManager.open(
                dataPath: directory.path,
                cacheRoot: directory.path,
              );
              CacheManager.instance = cache;
              Directory('${directory.path}/comics').createSync();
              File(
                '${directory.path}/local_path',
              ).writeAsStringSync('${directory.path}/comics');
              _historyOwner = _TestHistory();
              await _historyForView().init();
              await LocalManager().init();
              final horizontal = !mode.isTopToBottom;
              final png = img.encodePng(
                img.Image(
                  width: horizontal ? 400 : 100,
                  height: horizontal ? 100 : 400,
                ),
              );
              for (final chapter in ['one', 'two']) {
                final folder = Directory('${LocalManager().path}/book/$chapter')
                  ..createSync(recursive: true);
                File(
                  '${folder.path}/1.png',
                ).writeAsBytesSync(unavailable ? [1, 2, 3] : png);
                if (mode.isGallery) {
                  File('${folder.path}/2.png').writeAsBytesSync(png);
                }
              }
              await LocalManager().add(
                LocalComic(
                  id: 'book',
                  title: 'Book',
                  subtitle: '',
                  tags: const [],
                  directory: 'book',
                  chapters: _chapters,
                  cover: '',
                  comicType: ComicType.local,
                  downloadedChapters: const ['one', 'two'],
                  createdAt: DateTime(2026),
                ),
              );
            });
            await tester.pumpWidget(
              _libraryView(
                MaterialApp(
                  builder: (context, child) => ReaderPlatformEffectsScope(
                    coordinator: effects,
                    child: child!,
                  ),
                  navigatorKey: appNavigation.rootNavigatorKey,
                  home: Scaffold(body: OverlayWidget(_TestReader(key: key))),
                ),
              ),
            );
            final reader = key.currentState!;
            Future<void> pumpFrames(int count) async {
              for (var i = 0; i < count; i++) {
                await tester.pump(const Duration(milliseconds: 20));
                if (i % 10 == 0) {
                  await tester.runAsync(
                    () =>
                        Future<void>.delayed(const Duration(milliseconds: 10)),
                  );
                }
              }
            }

            if (unavailable) {
              settings['longPressAction'] = 'none';
              settings['autoReadingAcrossChapters'] = false;
              await pumpFrames(40);
              reader.autoReading.start();
              await pumpFrames(100);
              expect(reader.chapter, 1);
              expect(reader.page, 1);
              expect(reader.autoReading.status, AutoReadingStatus.waiting);
              reader.autoReading.stop();
              settings['autoReadingSkipUnavailableImages'] = true;
              reader.update();
              final viewport =
                  reader.imageViewController as AutoReadingImageViewport;
              for (
                var i = 0;
                i < 100 &&
                    viewport.autoReadingImages.state !=
                        AutoReadingImageState.failed;
                i++
              ) {
                await pumpFrames(5);
              }
              expect(
                viewport.autoReadingImages.state,
                AutoReadingImageState.failed,
              );
              final touch = await tester.startGesture(const Offset(10, 10));
              reader.autoReading.start();
              await pumpFrames(100);
              expect(reader.chapter, 1);
              expect(reader.page, 1);
              expect(reader.autoReading.status, AutoReadingStatus.paused);
              await touch.up();
              for (var i = 0; i < 100 && reader.autoReading.isActive; i++) {
                await pumpFrames(10);
              }
              expect(reader.chapter, 1);
              expect(reader.autoReading.status, AutoReadingStatus.stopped);
              settings['autoReadingAcrossChapters'] = true;
              reader.autoReading.start();
              for (var i = 0; i < 100 && reader.autoReading.isActive; i++) {
                await pumpFrames(10);
              }
              expect(reader.chapter, 2);
              expect(reader.autoReading.status, AutoReadingStatus.stopped);
              expect(tester.takeException(), isNull);
              return;
            }
            for (var i = 0; i < 30; i++) {
              await pumpFrames(5);
              if (reader.imageViewController case AutoReadingViewport viewport
                  when viewport.autoReadingReady) {
                break;
              }
            }
            expect(reader.imageViewController, isA<AutoReadingViewport>());
            expect(
              (reader.imageViewController as AutoReadingViewport)
                  .autoReadingReady,
              isTrue,
            );
            settings['longPressAction'] = 'zoom';
            expect(
              find.text(mode.isTopToBottom ? '100 × 400' : '400 × 100'),
              findsWidgets,
            );
            settings['showImageDimensions'] = false;
            reader.update();
            await pumpFrames(5);
            expect(
              find.text(mode.isTopToBottom ? '100 × 400' : '400 × 100'),
              findsNothing,
            );
            if (!mode.isGallery) {
              PhotoView flowPhoto() => tester.widget<PhotoView>(
                find.byWidgetPredicate(
                  (widget) => widget is PhotoView && widget.childSize != null,
                ),
              );
              final expectedWidth =
                  reader.size.width * (mode.isTopToBottom ? 0.6 : 1.0);
              expect(
                flowPhoto().childSize!.width,
                closeTo(expectedWidth, 0.01),
              );
              final chapter = reader.chapter;
              final page = reader.page;
              settings['readerSideMargin'] = 0;
              reader.update();
              await pumpFrames(10);
              expect(flowPhoto().childSize!.width, reader.size.width);
              settings['readerSideMargin'] = 30;
              settings['limitImageWidth'] = true;
              reader.update();
              await pumpFrames(10);
              final limitedWidth =
                  mode.isTopToBottom &&
                      reader.size.width / reader.size.height > 0.7
                  ? reader.size.height * 0.7
                  : reader.size.width;
              expect(
                flowPhoto().childSize!.width,
                closeTo(limitedWidth * (mode.isTopToBottom ? 0.4 : 1.0), 0.01),
              );
              settings['limitImageWidth'] = false;
              settings['readerSideMargin'] = 20;
              reader.update();
              await pumpFrames(10);
              expect(
                flowPhoto().childSize!.width,
                closeTo(expectedWidth, 0.01),
              );
              expect(reader.chapter, chapter);
              expect(reader.page, page);
            }
            await tester.longPressAt(const Offset(400, 250));
            await pumpFrames(20);
            expect(reader.autoReading.isActive, isFalse);
            expect(
              (reader.imageViewController as AutoReadingViewport)
                  .autoReadingReady,
              isTrue,
            );
            settings['longPressAction'] = 'autoReading';
            await tester.longPressAt(const Offset(400, 250));
            expect(reader.autoReading.isActive, isTrue);
            await tester.longPressAt(const Offset(400, 250));
            expect(reader.autoReading.isActive, isFalse);
            settings['longPressAction'] = 'none';
            await tester.longPressAt(const Offset(400, 250));
            expect(reader.autoReading.isActive, isFalse);
            settings['autoReadingAcrossChapters'] = false;
            reader.autoReading.start();
            await tester.pump();
            expect(screenAwake, isTrue);
            final hiddenChapter = reader.chapter;
            final hiddenPage = reader.page;
            final hiddenOffset = mode.isGallery
                ? null
                : (reader.imageViewController as ContinuousModeState)
                      .scrollController
                      .offset;
            reader.didChangeAppLifecycleState(AppLifecycleState.hidden);
            await pumpFrames(25);
            expect(screenAwake, isFalse);
            expect(reader.chapter, hiddenChapter);
            expect(reader.page, hiddenPage);
            if (hiddenOffset != null) {
              expect(
                (reader.imageViewController as ContinuousModeState)
                    .scrollController
                    .offset,
                hiddenOffset,
              );
            }
            expect(reader.autoReading.isActive, isTrue);
            reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await tester.pump();
            expect(screenAwake, isTrue);
            reader.didChangeAppLifecycleState(AppLifecycleState.paused);
            await tester.pump();
            expect(screenAwake, isFalse);
            reader.didChangeAppLifecycleState(AppLifecycleState.resumed);
            await tester.pump();
            expect(screenAwake, isTrue);
            settings['autoReadingKeepScreenOn'] = false;
            reader.update();
            await tester.pump();
            expect(screenAwake, isFalse);
            settings['autoReadingKeepScreenOn'] = true;
            reader.update();
            await tester.pump();
            expect(screenAwake, isTrue);
            if (!mode.isGallery) {
              final flow = reader.imageViewController as ContinuousModeState;
              final start = flow.scrollController.offset;
              await pumpFrames(25);
              expect(flow.scrollController.offset - start, closeTo(50, 3));
              flow.photoViewController.updateMultiple(
                scale: 2.0,
                position: Offset.zero,
              );
              flow.onScaleUpdate();
              final zoomedStart = flow.scrollController.offset;
              await pumpFrames(25);
              expect(flow.autoReadingReady, isTrue);
              expect(
                flow.scrollController.offset - zoomedStart,
                closeTo(25, 3),
                reason: 'Zoom must preserve screen-space reading speed.',
              );
              final firstTouch = await tester.startGesture(
                const Offset(350, 250),
                pointer: 1,
              );
              final secondTouch = await tester.startGesture(
                const Offset(450, 250),
                pointer: 2,
              );
              final heldOffset = flow.scrollController.offset;
              await pumpFrames(20);
              expect(flow.scrollController.offset, heldOffset);
              expect(flow.autoReadingReady, isFalse);
              await secondTouch.up();
              await firstTouch.up();
              await pumpFrames(5);
              // There is only one tall/wide image: page == maxPage must not stop scrolling.
              expect(reader.chapter, 1);
              expect(reader.autoReading.isActive, isTrue);
              settings['autoScrollSpeed'] = 1000;
            }
            for (var i = 0; i < 60 && reader.autoReading.isActive; i++) {
              await pumpFrames(10);
            }
            expect(reader.chapter, 1);
            expect(
              reader.autoReading.status,
              AutoReadingStatus.stopped,
              reason:
                  'Reading must reach the visible chapter end, including the zoomed tail.',
            );
            settings['autoReadingAcrossChapters'] = true;
            reader.autoReading.toggle();
            for (var i = 0; i < 60 && reader.autoReading.isActive; i++) {
              await pumpFrames(10);
            }
            expect(reader.chapter, 2);
            expect(reader.autoReading.status, AutoReadingStatus.stopped);
            await tester.pump();
            expect(screenAwake, isFalse);
            expect(tester.takeException(), isNull);
          } finally {
            key.currentState?.autoReading.stop();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 3));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.runAsync(() async => await cache?.dispose());
            CacheManager.instance = previousCache;
            LocalManager.current?.dispose();
            if (_historyOwner?.isInitialized == true) {
              _historyForView().close();
            }
            _historyOwner = previousHistory;
            _favoritesOwner = previousFavorites;
            Log.isMuted = previousLogMuted;
            previous.forEach((key, value) => appdata.settings[key] = value);
            directory.deleteSync(recursive: true);
          }
        },
        skip: !sqliteTestAvailable(),
      );
    }
  }
}

const _chapters = ComicChapters({'one': 'One', 'two': 'Two'});

class _TestReader extends Reader {
  _TestReader({required super.key})
    : super(
        onClosed: () {},
        type: ComicType.local,
        cid: 'book',
        name: 'Book',
        author: '',
        tags: const [],
        chapters: _chapters,
        history: History.fromMap({
          'id': 'book',
          'type': 0,
          'time': 1000,
          'title': 'Book',
          'subtitle': '',
          'cover': '',
          'ep': 1,
          'page': 1,
          'max_page': 1,
        }),
      );
  @override
  ReaderState createState() => _TestReaderState();
}

class _TestReaderState extends ReaderState {
  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  void updateHistory() {}
}

class _TestHistory extends HistoryManager {
  _TestHistory() : super.create();
  @override
  Future<void> addReadDuration(History history, Duration duration) async {}
}

LocalFavoritesManager? _favoritesOwner;
LocalFavoritesManager _favoritesForView() =>
    _favoritesOwner ??= LocalFavoritesManager.independent();
HistoryManager? _historyOwner;
HistoryManager _historyForView() => _historyOwner ??= HistoryManager.create();
Widget _libraryView(Widget child) {
  return FavoritesScope(
    manager: _favoritesForView(),
    child: HistoryScope(manager: _historyForView(), child: child),
  );
}
