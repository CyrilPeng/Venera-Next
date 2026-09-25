import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/auto_reading.dart';
import 'package:venera_next/features/reader/images.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/sync/data_sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  for (final mode in ReaderMode.values) {
    testWidgets(
      '${mode.key}: reads content before crossing chapters and stops at the end',
      (tester) async {
        final previous =
            jsonDecode(jsonEncode(appdata.toJson()['settings']))
                as Map<String, dynamic>;
        final previousFavorites = LocalFavoritesManager.cache;
        final previousHistory = HistoryManager.cache;
        final previousLogMuted = Log.isMuted;
        final directory = Directory.systemTemp.createTempSync('auto-reader-');
        final key = GlobalKey<_TestReaderState>();
        try {
          App.dataPath = directory.path;
          App.cachePath = directory.path;
          Log.isMuted = true;
          LocalFavoritesManager.cache = _Favorites();
          DataSync.debugDisableWindowCloseHandler = true;
          final settings = appdata.settings;
          settings['comicSpecificSettings'] = <String, dynamic>{};
          settings['deviceSpecificSettings'] = <String, dynamic>{};
          settings['autoReaderMode'] = false;
          settings['readerMode'] = mode.key;
          settings['readerScreenPicNumberForLandscape'] = 1;
          settings['readerScreenPicNumberForPortrait'] = 1;
          settings['autoScrollStyle'] = 'smooth';
          settings['autoScrollSpeed'] = 100;
          settings['autoPageTurningInterval'] = 1;
          settings['autoReadingAcrossChapters'] = true;
          settings['enableClockAndBatteryInfoInReader'] = false;
          settings['showPageNumberInReader'] = false;
          settings['eInkMode'] = false;
          settings['limitImageWidth'] = false;
          settings['language'] = 'en-US';
          LocalManager.resetForTesting();
          LocalManager.debugSkipComicSourceInit = true;
          await tester.runAsync(() async {
            Directory('${directory.path}/comics').createSync();
            File(
              '${directory.path}/local_path',
            ).writeAsStringSync('${directory.path}/comics');
            HistoryManager.cache = _TestHistory();
            await HistoryManager().init();
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
              File('${folder.path}/1.png').writeAsBytesSync(png);
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
            MaterialApp(
              navigatorKey: App.rootNavigatorKey,
              home: Scaffold(body: OverlayWidget(_TestReader(key: key))),
            ),
          );
          final reader = key.currentState!;
          Future<void> pumpFrames(int count) async {
            for (var i = 0; i < count; i++) {
              await tester.pump(const Duration(milliseconds: 20));
              if (i % 10 == 0) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
              }
            }
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
          if (!mode.isGallery) {
            final flow = reader.imageViewController as ContinuousModeState;
            final start = flow.scrollController.offset;
            await pumpFrames(25);
            expect(flow.scrollController.offset - start, closeTo(50, 3));
            // There is only one tall/wide image: page == maxPage must not stop scrolling.
            expect(reader.chapter, 1);
            expect(reader.autoReading.isActive, isTrue);
            settings['autoScrollSpeed'] = 1000;
          }
          for (var i = 0; i < 60 && reader.autoReading.isActive; i++) {
            await pumpFrames(10);
          }
          expect(reader.chapter, 1);
          expect(reader.autoReading.status, AutoReadingStatus.stopped);
          settings['autoReadingAcrossChapters'] = true;
          reader.autoReading.toggle();
          for (var i = 0; i < 60 && reader.autoReading.isActive; i++) {
            await pumpFrames(10);
          }
          expect(reader.chapter, 2);
          expect(reader.autoReading.status, AutoReadingStatus.stopped);
          expect(tester.takeException(), isNull);
        } finally {
          key.currentState?.autoReading.stop();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 3));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          LocalManager.resetForTesting();
          if (HistoryManager.cache?.isInitialized == true) {
            HistoryManager().close();
          }
          HistoryManager.cache = previousHistory;
          DataSync.resetForTesting();
          LocalFavoritesManager.cache = previousFavorites;
          Log.isMuted = previousLogMuted;
          previous.forEach((key, value) => appdata.settings[key] = value);
          directory.deleteSync(recursive: true);
        }
      },
      skip: !_sqliteAvailable(),
    );
  }
}

const _chapters = ComicChapters({'one': 'One', 'two': 'Two'});

class _TestReader extends Reader {
  _TestReader({required super.key})
    : super(
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

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHistory extends HistoryManager {
  _TestHistory() : super.create();
  @override
  Future<void> addReadDuration(History history, Duration duration) async {}
}
