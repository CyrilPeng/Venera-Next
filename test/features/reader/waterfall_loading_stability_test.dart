import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/continuous_data.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/image_work.dart';

class _Stream extends ImageStreamCompleter {
  void frame(int width, int height) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.grey, ui.BlendMode.src);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(width, height)));
    picture.dispose();
  }
}

class _Fixture {
  _Fixture({
    this.chapter = 1,
    this.vertical = true,
    this.reverse = false,
    int initialPage = 1,
  }) {
    navigation =
        ReaderController(
            pageCount: () => count,
            chapterCount: () => chapter,
            animationEnabled: () => false,
            viewport: () => viewport.current,
            onChanged: () {},
            onPageChanged: () {},
            onError: (error, _) => fail('$error'),
          )
          ..restoreChapter(chapter)
          ..replaceChapterImages(keys(chapter))
          ..reportPage(initialPage);
    for (var ch = 1; ch <= chapter; ch++) {
      for (var page = 1; page <= count; page++) {
        final provider = ReaderImageProvider(
          keys(ch)[page - 1],
          null,
          'loading-book',
          'chapter-$ch',
          page,
          enableResize: true,
        );
        final stream = streams[(ch, page)] = _Stream();
        PaintingBinding.instance.imageCache.putIfAbsent(provider, () => stream);
      }
    }
  }

  static const count = 8;
  static const size = Size(400, 600);
  final int chapter;
  final bool vertical, reverse;
  final work = ImageWork();
  final viewport = ReaderViewportBinding();
  final previous = Completer<List<String>>();
  final streams = <(int, int), _Stream>{};
  late final ReaderController navigation;
  ContinuousModeState get state => viewport.current! as ContinuousModeState;
  List<String> keys(int chapter) =>
      List.generate(count, (i) => 'file://controlled-$chapter-$i');
  void frame(int chapter, int page, {int width = 40, int height = 60}) =>
      streams[(chapter, page)]!.frame(width, height);
  Finder image(int chapter, int page) => find.byWidgetPredicate(
    (widget) =>
        widget is ComicImage &&
        widget.image is ReaderDisplayImageProvider &&
        (widget.image as ReaderDisplayImageProvider).image.eid ==
            'chapter-$chapter' &&
        (widget.image as ReaderDisplayImageProvider).image.page == page,
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ReaderContinuousView(
            data: ReaderContinuousData(
              vertical: vertical,
              reverse: reverse,
              crossChapter: true,
              firstChapter: chapter == 1,
              lastChapter: true,
              maxChapter: chapter,
              preloadCount: 0,
              splitWideImages: false,
              invertSplit: false,
              scrollSpeed: 1,
              limitImageWidth: false,
              sideMargin: 0,
              doubleTapCollect: false,
              centerLongPressZoom: true,
              sourceKey: null,
              comicId: 'loading-book',
            ),
            imageWork: work,
            navigation: navigation,
            loadChapter: (_, _) => previous.future,
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
            readImage: (_) async => null,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    if (!previous.isCompleted) previous.complete(keys(1));
    await tester.pumpWidget(const SizedBox());
    final closing = work.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pump();
    await closing;
    navigation.dispose();
    ComicImage.clear();
  }
}

void main() {
  testWidgets('initial loading keeps the page requested from history', (
    tester,
  ) async {
    final fixture = _Fixture(initialPage: 2);
    try {
      await fixture.mount(tester);
      for (final page in [1, 3, 2]) {
        fixture.frame(1, page);
        await tester.pump();
      }
      await fixture.settle(tester);
      expect(fixture.navigation.state.page, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'late previous chapter preserves the latest page and partial offset',
    (tester) async {
      final fixture = _Fixture(chapter: 2);
      try {
        for (var chapter = 1; chapter <= 2; chapter++) {
          for (var page = 1; page <= _Fixture.count; page++) {
            fixture.frame(chapter, page);
          }
        }
        await fixture.mount(tester);
        fixture.state.itemScrollController.jumpTo(index: 3, alignment: -0.35);
        await fixture.settle(tester);
        final before = tester.getRect(fixture.image(2, 3));
        final page = fixture.navigation.state.page;
        fixture.previous.complete(fixture.keys(1));
        await fixture.settle(tester);
        expect(
          tester.getRect(fixture.image(2, 3)).top,
          closeTo(before.top, 0.01),
        );
        expect(fixture.navigation.state.chapter, 2);
        expect(fixture.navigation.state.page, page);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final vertical in [true, false]) {
    for (final reverse in [false, true]) {
      for (final grow in [false, true]) {
        testWidgets(
          'late dimensions preserve the visible page before paint: vertical=$vertical reverse=$reverse grow=$grow',
          (tester) async {
            final fixture = _Fixture(vertical: vertical, reverse: reverse);
            try {
              for (var page = 2; page <= _Fixture.count; page++) {
                fixture.frame(1, page);
              }
              await fixture.mount(tester);
              fixture.state.scrollController.jumpTo(450);
              await fixture.settle(tester);
              final before = tester.getRect(fixture.image(1, 2));
              fixture.frame(
                1,
                1,
                width: vertical ? 40 : (grow ? 40 : 10),
                height: vertical ? (grow ? 80 : 20) : 40,
              );
              await tester.pump();
              expect(
                tester.getRect(fixture.image(1, 2)).topLeft,
                before.topLeft,
              );
              await fixture.settle(tester);
              expect(
                tester.getRect(fixture.image(1, 2)).topLeft,
                before.topLeft,
              );
              expect(tester.takeException(), isNull);
            } finally {
              await fixture.dispose(tester);
            }
          },
        );
      }
    }
  }

  for (final prepend in [false, true]) {
    testWidgets(
      'late loading keeps the active drag responsive: prepend=$prepend',
      (tester) async {
        final fixture = _Fixture(chapter: prepend ? 2 : 1);
        TestGesture? gesture;
        try {
          for (var chapter = 1; chapter <= fixture.chapter; chapter++) {
            for (var page = prepend ? 1 : 2; page <= _Fixture.count; page++) {
              fixture.frame(chapter, page);
            }
          }
          await fixture.mount(tester);
          fixture.state.scrollController.jumpTo(450);
          await fixture.settle(tester);
          gesture = await tester.startGesture(const Offset(200, 350));
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
          await gesture.moveBy(const Offset(0, -30));
          await tester.pump();
          final before = tester.getRect(fixture.image(fixture.chapter, 2));
          if (prepend) {
            fixture.previous.complete(fixture.keys(1));
          } else {
            fixture.frame(1, 1, height: 20);
          }
          await tester.pump();
          expect(
            fixture.state.scrollController.position.isScrollingNotifier.value,
            isTrue,
          );
          expect(
            tester.getRect(fixture.image(fixture.chapter, 2)).topLeft,
            before.topLeft,
          );
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
          expect(
            tester.getRect(fixture.image(fixture.chapter, 2)).top,
            closeTo(before.top - 40, 0.01),
          );
          await gesture.up();
          gesture = null;
          await fixture.settle(tester);
          expect(tester.takeException(), isNull);
        } finally {
          await gesture?.up();
          await fixture.dispose(tester);
        }
      },
    );
  }
}
