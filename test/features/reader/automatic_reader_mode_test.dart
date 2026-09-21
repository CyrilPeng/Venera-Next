import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/models.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/features/sync/data_sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/foundation/comic_type.dart';

void main() {
  late Directory directory;
  late Map<String, dynamic> previousSettings;
  LocalFavoritesManager? previousFavorites;
  final settings = appdata.settings;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reader-mode-regression-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    previousFavorites = LocalFavoritesManager.cache;
    LocalFavoritesManager.cache = _Favorites();
    DataSync.debugDisableWindowCloseHandler = true;
    settings['autoReaderMode'] = true;
    settings['readerMode'] = 'galleryRightToLeft';
    settings['longStripReaderMode'] = 'continuousTopToBottom';
    settings['pagedReaderMode'] = 'galleryRightToLeft';
    settings['deviceSpecificSettings'] = <String, dynamic>{};
    settings['comicSpecificSettings'] = <String, dynamic>{};
    settings['comicLayoutDetections'] = <String, dynamic>{};
    settings['readerScreenPicNumberForLandscape'] = 2;
    settings['showSingleImageOnFirstPage'] = false;
    settings['enablePageAnimation'] = false;
    settings['language'] = 'en-US';
  });

  tearDown(() {
    DataSync.resetForTesting();
    LocalFavoritesManager.cache = previousFavorites;
    previousSettings.forEach((key, value) => settings[key] = value);
    directory.deleteSync(recursive: true);
  });

  void readerTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
      }
    });
  }

  Future<_ReaderHarnessState> mount(WidgetTester tester) async {
    final key = GlobalKey<_ReaderHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: OverlayWidget(_ReaderHarness(key: key)),
      ),
    );
    return key.currentState!;
  }

  readerTest(
    'default-off leaves mode and navigation unchanged and starts no probe',
    (tester) async {
      settings['autoReaderMode'] = false;
      final reader = await mount(tester);
      await reader.prepareReadingMode();
      expect(reader.probes, isEmpty);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      expect((reader.chapter, reader.page), (2, 3));
      final controller = _Controller();
      reader.imageViewController = controller;
      expect(reader.toNextPage(), isTrue);
      expect(controller.visited, [4]);
    },
  );

  readerTest(
    'first open waits up to 700ms then applies a late result with the actual mode toast',
    (tester) async {
      final reader = await mount(tester);
      var ready = false;
      unawaited(reader.prepareReadingMode().then((_) => ready = true));
      await tester.pump(const Duration(milliseconds: 699));
      expect(ready, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(ready, isTrue);
      expect(reader.isDetectingLayout, isTrue);
      expect(reader.mode, ReaderMode.galleryRightToLeft);
      reader.probes.single.finish(ComicLayout.longStrip);
      await tester.pump();
      await tester.pump();
      expect(reader.mode, ReaderMode.continuousTopToBottom);
      expect(
        find.text('Switched to Continuous (Top to Bottom)'),
        findsOneWidget,
      );
      expect(find.text('Apply reading preference'), findsNothing);
      expect((reader.chapter, reader.page), (2, 5));
      expect(reader.imageViewController, isNull);
      expect(settings.comicLayout('comic', 'local'), ComicLayout.longStrip);
      final controller = _Controller();
      reader.imageViewController = controller;
      expect(reader.toNextPage(), isTrue);
      expect(reader.toPrevPage(), isTrue);
      expect(controller.visited, [6, 5]);
      expect(reader.chapter, 2);
      expect(reader.toNextChapter(), isTrue);
      expect((reader.chapter, reader.page), (3, 1));
    },
  );

  readerTest('fast detection releases the initial wait before its deadline', (
    tester,
  ) async {
    final reader = await mount(tester);
    var ready = false;
    unawaited(reader.prepareReadingMode().then((_) => ready = true));
    reader.probes.single.finish(ComicLayout.longStrip);
    await tester.pump(const Duration(milliseconds: 10));
    expect(ready, isTrue);
    expect(reader.mode, ReaderMode.continuousTopToBottom);
  });

  for (final action in ['disable', 'override']) {
    readerTest('late result respects $action while detection was pending', (
      tester,
    ) async {
      final reader = await mount(tester);
      final detection = reader.detectLayout();
      if (action == 'disable') {
        settings['autoReaderMode'] = false;
      } else {
        settings.setComicReaderModeOverride(
          'comic',
          'local',
          'galleryLeftToRight',
        );
        reader.applyReadingMode(ReaderMode.galleryLeftToRight);
      }
      final current = reader.mode;
      reader.probes.single.finish(ComicLayout.longStrip);
      await detection;
      await tester.pump();
      expect(reader.mode, current);
      expect(find.textContaining('Switched to'), findsNothing);
    });
  }

  readerTest('unknown or unchanged results do not switch or notify', (
    tester,
  ) async {
    final reader = await mount(tester);
    final unknown = reader.detectLayout();
    reader.probes.last.finish(ComicLayout.unknown);
    await unknown;
    final same = reader.detectLayout(force: true);
    reader.probes.last.finish(ComicLayout.paged);
    await same;
    await tester.pump();
    expect(reader.mode, ReaderMode.galleryRightToLeft);
    expect((reader.chapter, reader.page), (2, 3));
    expect(find.textContaining('Switched to'), findsNothing);
  });

  readerTest(
    'leaving the reader cancels recognition and ignores its late result',
    (tester) async {
      final reader = await mount(tester);
      final detection = reader.detectLayout();
      final probe = reader.probes.single;
      await tester.pumpWidget(const SizedBox.shrink());
      expect(probe.cancelled, isTrue);
      probe.finish(ComicLayout.longStrip);
      await detection;
      await tester.pump(const Duration(seconds: 1));
      expect(settings.comicLayout('comic', 'local'), ComicLayout.unknown);
      expect(tester.takeException(), isNull);
    },
  );

  readerTest(
    'mode switch invalidates an old page animation and accepts new navigation',
    (tester) async {
      settings['enablePageAnimation'] = true;
      final reader = await mount(tester);
      final oldController = _Controller();
      reader.imageViewController = oldController;
      reader.toNextPage();
      expect(reader.isPageAnimating, isTrue);
      reader.applyReadingMode(ReaderMode.continuousTopToBottom);
      expect(reader.isPageAnimating, isFalse);
      oldController.animation.complete();
      await tester.pump();
      expect(reader.isPageAnimating, isFalse);
      settings['enablePageAnimation'] = false;
      final currentController = _Controller();
      reader.imageViewController = currentController;
      reader.toNextPage();
      expect(currentController.visited, [6]);
      expect((reader.chapter, reader.page), (2, 6));
    },
  );

  readerTest(
    'single cover and paired pages map back to the same source image',
    (tester) async {
      settings['showSingleImageOnFirstPage'] = true;
      final reader = await mount(tester);
      expect(
        reader.page,
        3,
      ); // Images 4 and 5 are displayed together after the cover.
      reader.applyReadingMode(ReaderMode.waterfallTopToBottom);
      expect((reader.chapter, reader.page), (2, 4));
      reader.applyReadingMode(ReaderMode.galleryRightToLeft);
      expect((reader.chapter, reader.page), (2, 3));
    },
  );
}

// Keep the real ReaderState lifecycle and navigation, isolating native window,
// database and image-rendering services. Probe behavior is tested separately.
class _ReaderHarness extends Reader {
  _ReaderHarness({required super.key})
    : super(
        type: ComicType.local,
        cid: 'comic',
        name: 'Comic',
        author: '',
        tags: const [],
        chapters: const ComicChapters({
          'one': 'One',
          'two': 'Two',
          'three': 'Three',
        }),
        history: _History(),
        initialChapter: 2,
        initialPage: 5,
      );
  @override
  ReaderState createState() => _ReaderHarnessState();
}

class _ReaderHarnessState extends ReaderState {
  final probes = <_Probe>[];
  @override
  void initState() {
    super.initState();
    images = List.generate(12, (i) => 'image-$i');
  }

  @override
  ComicLayoutProbe createLayoutProbe() {
    final probe = _Probe();
    probes.add(probe);
    return probe;
  }

  @override
  Future<void> saveReadingSettings() async {}
  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  void onPageChanged() {}
  @override
  Widget build(BuildContext context) => Text('${mode.key}:$chapter:$page');
}

class _Probe extends ComicLayoutProbe {
  final completion = Completer<ComicLayoutDetection>();
  bool cancelled = false;
  void finish(ComicLayout layout) =>
      completion.complete(ComicLayoutDetection(layout, 6));
  @override
  Future<ComicLayoutDetection> detect({
    required List<String> images,
    required String? sourceKey,
    required String comicId,
    required String chapterId,
  }) => completion.future;
  @override
  void cancel() {
    cancelled = true;
  }
}

class _Controller extends Fake implements ReaderImageViewController {
  final visited = <int>[];
  final animation = Completer<void>();
  @override
  void toPage(int page) => visited.add(page);
  @override
  Future<void> animateToPage(int page) => animation.future;
  @override
  bool toChapter(int chapter, {bool toLastPage = false}) => false;
}

class _History extends Fake implements History {}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
