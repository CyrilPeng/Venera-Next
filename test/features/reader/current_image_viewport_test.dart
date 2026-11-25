import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_data.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/image_export.dart';
import 'package:venera_next/features/reader/image_picker.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  for (final mode in ['vertical', 'ltr', 'rtl']) {
    for (final size in [const Size(375, 667), const Size(800, 400)]) {
      testWidgets(
        '$mode $size: dominant page and save/share agree in both directions',
        (tester) async {
          final fixture = _Fixture(mode: mode, size: size);
          try {
            await fixture.mount(tester);
            final picker = fixture.picker();
            addTearDown(picker.dispose);
            for (final alignment in [0.2, 0.8, 0.2]) {
              fixture.state.itemScrollController.jumpTo(
                index: 2,
                alignment: alignment,
              );
              await fixture.settle(tester);
              final expected = alignment < 0.5 ? 2 : 1;
              expect(fixture.navigation.state.page, expected);
              expect(fixture.state.currentImageRange, (expected - 1, expected));
              for (final sharing in [false, true]) {
                ReaderImageSelection? selected;
                final exported = <String>[];
                final exporter = ReaderImageExporter(
                  work: fixture.work,
                  select: () async {
                    final request = fixture.exportRequest();
                    return request.resolve((await picker.pick())?.index);
                  },
                  read: (image) async {
                    selected = image;
                    return Uint8List.fromList([1, 2, 3]);
                  },
                  save: (image) => exported.add(image.filename),
                  share: (image) => exported.add(image.filename),
                  onError: (error, _) => fail('$error'),
                );
                await exporter.export(sharing: sharing);
                expect(selected?.imageNumber, expected);
                expect(selected?.chapter, 1);
                expect(exported.single, contains('_EP1_P$expected'));
                await exporter.dispose();
              }
            }
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
          }
        },
      );
    }
  }

  for (final mode in ['ltr', 'rtl']) {
    testWidgets('$mode: animated navigation retains an equal-area target', (
      tester,
    ) async {
      final fixture = _Fixture(
        mode: mode,
        size: const Size(700, 600),
        imageSize: const Size(100, 400),
        imageCount: 10,
        animatePages: true,
      );
      try {
        await fixture.mount(tester);
        expect(fixture.navigation.toPage(4, animated: false), isTrue);
        await fixture.settle(tester);
        expect(fixture.navigation.state.page, 4);
        for (final target in [5, 10, 6]) {
          expect(fixture.navigation.toPage(target), isTrue);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await fixture.settle(tester);
          expect(fixture.navigation.state.pendingPage, isNull);
          expect(fixture.navigation.state.page, target);
          expect(fixture.state.currentImageRange, (target - 1, target));
        }
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('decoded image proportions refresh selection without scrolling', (
    tester,
  ) async {
    final fixture = _Fixture(shortPage: 1, imageCount: 2);
    try {
      await fixture.mount(tester);
      expect(fixture.state.scrollController.offset, 0);
      expect(fixture.navigation.state.page, 2);
      expect(fixture.state.currentImageRange, (1, 2));
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('narrowed image margins keep their page after zoom and pan', (
    tester,
  ) async {
    final fixture = _Fixture(
      size: const Size(800, 600),
      imageSize: const Size(800, 1200),
      sideMargin: 20,
    );
    try {
      await fixture.mount(tester);
      final state = fixture.state;
      for (final zoom in [false, true]) {
        if (zoom) {
          state.photoViewController.scale = 1.5;
          state.photoViewController.position = const Offset(40, 0);
          await fixture.settle(tester);
        }
        final image = state.imageStates
            .whereType<ComicImageState>()
            .singleWhere((state) {
              final source =
                  (state.widget.image as ReaderDisplayImageProvider).image;
              return source.page == 1 && state.visibleInReader;
            });
        final bounds = tester.getRect(find.byWidget(image.widget));
        final point = Offset(
          4,
          bounds.center.dy.clamp(4, fixture.size.height - 4),
        );
        expect(bounds.contains(point), isFalse);
        expect(state.getImageIndexByOffset(point), 0);
        await tester.runAsync(() => state.getImageByOffset(point));
        expect(fixture.reads.single.chapterId, 'chapter-1');
        expect(fixture.reads.single.imageKey, fixture.imageKeys.first);
        fixture.reads.clear();
      }
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'a short final image does not override the dominant page at scroll end',
    (tester) async {
      final fixture = _Fixture(shortPage: 3);
      try {
        await fixture.mount(tester);
        fixture.state.itemScrollController.jumpTo(index: 3);
        await fixture.settle(tester);
        final controller = fixture.state.scrollController;
        controller.jumpTo(controller.position.maxScrollExtent);
        await fixture.settle(tester);
        expect(fixture.navigation.state.page, 2);
        final picker = fixture.picker();
        expect((await picker.pick())?.index, 1);
        picker.dispose();
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'waterfall selection excludes chapter dividers and keeps chapter/page identity',
    (tester) async {
      final fixture = _Fixture(crossChapter: true);
      try {
        await fixture.mount(tester);
        fixture.state.itemScrollController.jumpTo(index: 3);
        await fixture.settle(tester);
        expect(fixture.loadedChapters, contains(2));
        // Only the next chapter's divider is visible at the bottom.
        fixture.state.itemScrollController.jumpTo(index: 4, alignment: 0.98);
        await fixture.settle(tester);
        expect(fixture.navigation.state.chapter, 1);
        expect(fixture.navigation.state.page, 3);
        fixture.state.itemScrollController.jumpTo(index: 4, alignment: 0.1);
        await fixture.settle(tester);
        expect(fixture.navigation.state.chapter, 2);
        expect(fixture.navigation.state.page, 1);
        final picker = fixture.picker();
        final selection = fixture.exportRequest().resolve(
          (await picker.pick())?.index,
        );
        expect(selection?.chapterId, 'chapter-2');
        expect(selection?.chapter, 2);
        expect(selection?.imageNumber, 1);
        picker.dispose();
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'zoom panning updates selection without changing the scroll offset',
    (tester) async {
      final fixture = _Fixture();
      try {
        await fixture.mount(tester);
        fixture.state.itemScrollController.jumpTo(index: 2, alignment: 0.4);
        await fixture.settle(tester);
        expect(fixture.navigation.state.page, 2);
        final offset = fixture.state.scrollController.offset;
        fixture.state.photoViewController.scale = 2;
        fixture.state.photoViewController.position = const Offset(0, 400);
        await fixture.settle(tester);
        expect(fixture.state.scrollController.offset, offset);
        expect(fixture.navigation.state.page, 1);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('a hidden crossfade list cannot become the current page early', (
    tester,
  ) async {
    final fixture = _Fixture(imageCount: 30);
    try {
      await fixture.mount(tester);
      final scrolling = fixture.state.itemScrollController.scrollTo(
        index: 20,
        duration: const Duration(milliseconds: 400),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(fixture.navigation.state.page, lessThan(10));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await scrolling;
      await fixture.settle(tester);
      expect(fixture.navigation.state.page, 20);
    } finally {
      await fixture.dispose(tester);
    }
  });
}

class _Fixture {
  _Fixture({
    this.mode = 'vertical',
    this.size = const Size(400, 600),
    this.crossChapter = false,
    this.sideMargin = 0,
    Size? imageSize,
    int? shortPage,
    int imageCount = 3,
    bool animatePages = false,
  }) {
    final dimensions = imageSize ?? size;
    final normal = File('${directory.path}/page.png')
      ..writeAsBytesSync(
        img.encodePng(
          img.Image(
            width: dimensions.width.round(),
            height: dimensions.height.round(),
          ),
        ),
      );
    imageKeys = List.filled(imageCount, 'file://${normal.path}');
    if (shortPage != null) {
      final short = File('${directory.path}/short.png')
        ..writeAsBytesSync(
          img.encodePng(img.Image(width: size.width.round(), height: 30)),
        );
      imageKeys[shortPage - 1] = 'file://${short.path}';
    }
    navigation = ReaderController(
      pageCount: () => navigation.content.images?.length ?? 0,
      chapterCount: () => crossChapter ? 2 : 1,
      animationEnabled: () => animatePages,
      viewport: () => viewport.current,
      onChanged: () {},
      onPageChanged: () {},
      onError: (error, _) => fail('$error'),
    )..replaceChapterImages(imageKeys);
  }

  final String mode;
  final Size size;
  final bool crossChapter;
  final double sideMargin;
  final directory = Directory.systemTemp.createTempSync(
    'current-reader-image-',
  );
  final work = ImageWork();
  final viewport = ReaderViewportBinding();
  final loadedChapters = <int>[];
  final reads = <ReaderImageAddress>[];
  late final List<String> imageKeys;
  late final ReaderController navigation;
  ContinuousModeState get state => viewport.current! as ContinuousModeState;

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderContinuousView(
          imageWork: work,
          data: ReaderContinuousData(
            vertical: mode == 'vertical',
            reverse: mode == 'rtl',
            crossChapter: crossChapter,
            firstChapter: true,
            lastChapter: !crossChapter,
            maxChapter: crossChapter ? 2 : 1,
            preloadCount: 0,
            splitWideImages: false,
            invertSplit: false,
            scrollSpeed: 1,
            limitImageWidth: false,
            sideMargin: sideMargin,
            doubleTapCollect: false,
            centerLongPressZoom: true,
            sourceKey: null,
            comicId: 'book',
          ),
          navigation: navigation,
          loadChapter: (chapter, scope) async {
            scope.check();
            loadedChapters.add(chapter);
            return [imageKeys.first];
          },
          chapterId: (chapter) => 'chapter-$chapter',
          chapterTitle: (chapter) => 'Chapter $chapter',
          onViewportChanged: viewport.update,
          onUpdate: () {},
          onFloatingButton: (_) {},
          onCollectImage: () {},
          onActiveChapterChanged: () {},
          onContentLoading: (_) {},
          onPreviousError: (error, _) => fail('$error'),
          onNavigationError: (_, error, _) => fail('$error'),
          readerSize: () => size,
          readImage: (image) async {
            reads.add(image);
            return Uint8List(0);
          },
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => pumpEventQueue());
      final visible = state.imageStates.whereType<ComicImageState>().where(
        (image) => image.visibleInReader,
      );
      if (i >= 4 &&
          visible.isNotEmpty &&
          visible.every((image) => image.readyForAutoReading)) {
        await tester.pump();
        return;
      }
    }
    fail('Reader images did not finish loading');
  }

  ReaderImagePicker picker() => ReaderImagePicker(
    current: () => ReaderImagePickContext(
      viewport: state,
      images: navigation.content.images!,
      chapter: navigation.state.chapter,
    ),
    selectPosition: () async =>
        throw StateError('Single current page should not need an overlay'),
  );

  ReaderImageExportRequest exportRequest() => ReaderImageExportRequest(
    images: navigation.content.images!,
    sourceKey: 'local',
    comicId: 'book',
    chapterId: 'chapter-${navigation.state.chapter}',
    title: 'Book',
    chapter: navigation.state.chapter,
    isCurrent: () => true,
  );

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var completed = false;
    final closing = work.dispose();
    unawaited(closing.whenComplete(() => completed = true));
    while (!completed) {
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }
    await closing;
    navigation.dispose();
    await tester.runAsync(() async => directory.deleteSync(recursive: true));
  }
}
