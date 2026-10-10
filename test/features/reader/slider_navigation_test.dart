import 'package:venera_next/features/favorites/favorites_scope.dart';
import 'package:venera_next/features/history/history_scope.dart';
import 'package:venera_next/features/reader/platform_effects.dart'
    show ReaderPlatformEffectsScope;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/reader/scaffold.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  for (final rapid in [false, true]) {
    testWidgets('300-page slider jump preserves touch scrolling (rapid=$rapid)', (
      tester,
    ) async {
      final previous =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
      final previousFavorites = _favoritesOwner;
      final previousHistory = _historyOwner;
      final directory = Directory.systemTemp.createTempSync(
        'slider-navigation-',
      );
      final key = GlobalKey<_ReaderState>();
      Log.isMuted = true;
      try {
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        _favoritesOwner = _Favorites();
        final settings = appdata.settings;
        settings['comicSpecificSettings'] = <String, dynamic>{};
        settings['deviceSpecificSettings'] = <String, dynamic>{};
        settings['autoReaderMode'] = false;
        settings['readerMode'] = 'continuousTopToBottom';
        settings['enablePageAnimation'] = true;
        settings['enableClockAndBatteryInfoInReader'] = false;
        settings['showPageNumberInReader'] = false;
        settings['eInkMode'] = false;
        settings['limitImageWidth'] = false;
        settings['preloadImageCount'] = 1;
        settings['language'] = 'en-US';
        LocalManager.current?.dispose();
        LocalManager(initializeSources: () async {});
        await tester.runAsync(() async {
          Directory('${directory.path}/comics').createSync();
          File(
            '${directory.path}/local_path',
          ).writeAsStringSync('${directory.path}/comics');
          _historyOwner = _TestHistory();
          await _historyForView().init();
          await LocalManager().init();
          final png = img.encodePng(img.Image(width: 100, height: 200));
          final folder = Directory('${LocalManager().path}/book/one')
            ..createSync(recursive: true);
          for (var i = 1; i <= 300; i++) {
            File('${folder.path}/$i.png').writeAsBytesSync(png);
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
              downloadedChapters: const ['one'],
              createdAt: DateTime(2026),
            ),
          );
        });
        await tester.pumpWidget(
          _libraryView(
            MaterialApp(
              builder: (context, child) =>
                  ReaderPlatformEffectsScope(child: child!),
              navigatorKey: appNavigation.rootNavigatorKey,
              home: Scaffold(body: OverlayWidget(_Reader(key: key))),
            ),
          ),
        );
        Future<void> frames(int count) async {
          for (var i = 0; i < count; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            if (i % 10 == 0) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
          }
        }

        final reader = key.currentState!;
        for (var i = 0; i < 30 && reader.imageViewController == null; i++) {
          await frames(5);
        }
        expect(reader.maxPage, 300);
        expect(reader.imageViewController, isA<ContinuousModeState>());
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await frames(15);
        final slider = tester.widget<Slider>(find.byType(Slider).first);
        // A slider can emit multiple destination changes before the next frame,
        // while the positioned list has not mounted its transition list yet.
        if (rapid) slider.onChanged!(150);
        slider.onChanged!(200);
        await frames(50);
        expect(reader.isPageAnimating, isFalse);
        expect(reader.page, 200);
        scaffold.openOrClose();
        await frames(15);
        final flow = reader.imageViewController as ContinuousModeState;
        final before = flow.scrollController.offset;
        await tester.dragFrom(const Offset(400, 400), const Offset(0, -220));
        await frames(15);
        expect(flow.scrollController.offset, greaterThan(before + 50));
        final after = flow.scrollController.offset;
        await tester.dragFrom(const Offset(400, 150), const Offset(0, 220));
        await frames(15);
        expect(flow.scrollController.offset, lessThan(after - 50));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        LocalManager.current?.dispose();
        if (_historyOwner?.isInitialized == true) {
          _historyForView().close();
        }
        _historyOwner = previousHistory;
        _favoritesOwner = previousFavorites;
        Log.isMuted = false;
        previous.forEach((key, value) => appdata.settings[key] = value);
        await tester.runAsync(() async {
          await appdata.saveData(false);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await directory.delete(recursive: true);
        });
      }
    });
  }
}

const _chapters = ComicChapters({'one': 'One'});

class _Reader extends Reader {
  _Reader({required super.key})
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
          'max_page': 300,
        }),
      );
  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
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
  int get connectionGeneration => 1;

  @override
  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) async {
    checkActive?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
