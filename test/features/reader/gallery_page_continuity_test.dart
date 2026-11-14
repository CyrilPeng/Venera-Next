import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/src/photo_view_wrappers.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/gallery_data.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  testWidgets(
    'unchanged gallery preloads are shared and resume after exit holds',
    (tester) async {
      final fixture = _Fixture('ltr', preloadCount: 1);
      var starts = 0;
      final detach = fixture.work.retainTasks((_) {
        starts++;
        return () {};
      });
      try {
        await fixture.mount(tester);
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();
        }
        final before = starts;
        for (var i = 0; i < 5; i++) {
          fixture.gallery.cache(1);
          await tester.pump();
        }
        expect(starts, before);
        final release = fixture.work.holdForExit();
        fixture.gallery.cache(1);
        release();
        await fixture.decode(tester, () => fixture.gallery.autoReadingReady);
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();
        }
        expect(starts, greaterThan(before));
        final resumed = starts;
        fixture.gallery.cache(1);
        await tester.pump();
        expect(starts, resumed);
        expect(tester.takeException(), isNull);
      } finally {
        detach();
        await fixture.dispose(tester);
      }
    },
  );

  for (final direction in ['ltr', 'rtl', 'vertical']) {
    testWidgets(
      'interrupted $direction turn resets the retained page in place',
      (tester) async {
        final fixture = _Fixture(direction);
        try {
          await fixture.mount(tester);
          final element = tester.element(fixture.wrapper(1));
          final frame = fixture.paintedImage(1)!.image;
          final controller = fixture.gallery.photoViewControllers[1]!;
          final initial = controller.getInitialScale!()!;
          controller.scale = initial * 1.5;
          final forward = fixture.gallery.animateToPage(2);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          await fixture.decode(
            tester,
            () => fixture.paintedImage(2)?.image != null,
          );
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(fixture.navigation.state.page, 2);
          controller.animateScale!(initial * 3, const Offset(50, 30));
          final returning = fixture.gallery.animateToPage(1);
          await tester.pump();
          for (var i = 0; i < 18; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.element(fixture.wrapper(1)), same(element));
            expect(fixture.paintedImage(1)?.image, same(frame));
            expect(fixture.gallery.photoViewControllers[1], same(controller));
          }
          await forward;
          await returning;
          await tester.pumpAndSettle();
          expect(controller.scale, closeTo(initial, .01));
          expect(controller.position, Offset.zero);
          expect(fixture.navigation.state.page, 1);
          expect(fixture.gallery.autoReadingReady, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );

    for (final keepCache in [false, true]) {
      testWidgets(
        'loaded incoming page keeps its painted frame on $direction entry; cache=$keepCache',
        (tester) async {
          final fixture = _Fixture(direction);
          final cache = PaintingBinding.instance.imageCache;
          final oldLimit = cache.maximumSize;
          if (!keepCache) cache.maximumSize = 0;
          try {
            await fixture.mount(tester);
            await fixture.turnWithoutDiscardingFrame(tester, 2);
            await fixture.turnWithoutDiscardingFrame(tester, 1);
            expect(tester.takeException(), isNull);
          } finally {
            await fixture.dispose(tester);
            cache.maximumSize = oldLimit;
            cache.clear();
            cache.clearLiveImages();
          }
        },
      );
    }
  }
}

class _Fixture {
  _Fixture(this.direction, {this.preloadCount = 0});
  final String direction;
  final int preloadCount;
  final directory = Directory.systemTemp.createTempSync('gallery-continuity-');
  final work = ImageWork();
  final viewport = ReaderViewportBinding();
  final key = GlobalKey<GalleryModeState>();
  final repaint = GlobalKey();
  final size = const Size(300, 450);
  late ReaderGalleryData data;
  late final navigation = ReaderController(
    pageCount: () => data.totalPages,
    chapterCount: () => 1,
    animationEnabled: () => true,
    viewport: () => viewport.current,
    onChanged: () {},
    onPageChanged: () {},
    onError: (error, stack) => fail('$error\n$stack'),
  );
  GalleryModeState get gallery => key.currentState!;

  Finder wrapper(int page) => find.byWidgetPredicate(
    (widget) =>
        widget is ImageWrapper &&
        widget.imageProvider is ReaderDisplayImageProvider &&
        (widget.imageProvider as ReaderDisplayImageProvider).imageKey ==
            data.images[page - 1],
  );

  RawImage? paintedImage(int page) {
    final images = find.descendant(
      of: wrapper(page),
      matching: find.byType(RawImage),
    );
    return images.evaluate().isEmpty
        ? null
        : images.evaluate().single.widget as RawImage;
  }

  Future<void> decode(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }
    expect(ready(), isTrue);
  }

  Future<void> mount(WidgetTester tester) async {
    final images = <String>[];
    for (var page = 1; page <= 2; page++) {
      final pixels = img.Image(width: 60, height: 90)
        ..clear(
          page == 1 ? img.ColorRgb8(30, 100, 180) : img.ColorRgb8(180, 60, 30),
        );
      final file = File('${directory.path}/$page.png')
        ..writeAsBytesSync(img.encodePng(pixels));
      images.add('file://${file.path}');
    }
    navigation.replaceChapterImages(images);
    data = ReaderGalleryData(
      content: navigation.content,
      layout: const ReaderPageLayout(
        imagesPerPage: 1,
        singleImageOnFirstPage: false,
      ),
      vertical: direction == 'vertical',
      reverse: direction == 'rtl',
      commentsAtEnd: false,
      firstChapter: true,
      lastChapter: true,
      preloadCount: preloadCount,
      doubleTapCollect: false,
      centerLongPressZoom: true,
      pageAnimation: true,
      sourceKey: null,
      comicId: 'continuity',
      chapterId: 'one',
      observeImageReadiness: true,
    );
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: direction == 'rtl' ? Brightness.dark : Brightness.light,
        ),
        home: RepaintBoundary(
          key: repaint,
          child: ReaderGalleryView(
            key: key,
            data: data,
            imageWork: work,
            navigation: navigation,
            onViewportChanged: viewport.update,
            onReady: () {},
            onPageReported: (_, _) {},
            onChapterChanged: () {},
            onCollectImage: () {},
            readerSize: () => size,
            readImage: (_) async => null,
          ),
        ),
      ),
    );
    await decode(tester, () => paintedImage(1)?.image != null);
  }

  Future<void> turnWithoutDiscardingFrame(
    WidgetTester tester,
    int target,
  ) async {
    final turning = gallery.animateToPage(target);
    await tester.pump();
    // Decode as soon as the neighbour mounts, before fast scrolling can defer
    // image resolution. Keep the animation clock still during the real I/O.
    await tester.pump(const Duration(milliseconds: 1));
    await decode(tester, () => paintedImage(target)?.image != null);
    final incoming = tester.element(wrapper(target));
    final frame = paintedImage(target)!.image;
    final controller = gallery.photoViewControllers[target];
    expect(navigation.state.page, isNot(target));
    var checkedPaint = false;
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.element(wrapper(target)),
        same(incoming),
        reason:
            'Selecting an already loaded page must not recreate its image subtree',
      );
      expect(
        paintedImage(target)?.image,
        same(frame),
        reason:
            'No background/loading frame may replace an already painted static image',
      );
      expect(gallery.photoViewControllers[target], same(controller));
      if (!checkedPaint && navigation.state.page == target) {
        await checkPaint(tester, target);
        checkedPaint = true;
      }
    }
    await turning;
    expect(navigation.state.page, target);
    expect(gallery.autoReadingReady, isTrue);
    expect(checkedPaint, isTrue);
  }

  Future<void> checkPaint(WidgetTester tester, int target) async {
    await tester.runAsync(() async {
      final boundary =
          repaint.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (final fraction in [.25, .5, .75]) {
          final x = (image.width * fraction).floor();
          final y = (image.height * fraction).floor();
          final offset = (y * image.width + x) * 4;
          final rgb = List.generate(
            3,
            (channel) => pixels.getUint8(offset + channel),
          );
          expect(
            rgb,
            anyOf(equals([30, 100, 180]), equals([180, 60, 30])),
            reason:
                'The selection frame must paint the pages, not the background',
          );
        }
        final output = Platform.environment['PHOTO_CONTINUITY_QA_DIR'];
        if (output != null) {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$direction-to-$target.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        }
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var settled = false;
    final closing = work.dispose().whenComplete(() => settled = true);
    for (var i = 0; i < 100 && !settled; i++) {
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
    }
    await closing;
    navigation.dispose();
    await tester.binding.setSurfaceSize(null);
    await tester.runAsync(() => directory.delete(recursive: true));
  }
}
