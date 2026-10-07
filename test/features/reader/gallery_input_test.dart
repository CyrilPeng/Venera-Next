import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/features/reader/gallery_data.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/image_picker.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';

void main() {
  for (final direction in ['ltr', 'rtl', 'vertical']) {
    testWidgets(
      'standalone gallery uses injected inputs and actions ($direction)',
      (tester) async {
        final size = direction == 'ltr'
            ? const Size(375, 667)
            : direction == 'rtl'
            ? const Size(667, 375)
            : const Size(1024, 768);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repaint = GlobalKey();
        final directory = Directory.systemTemp.createTempSync('gallery-input-');
        final pixels = img.Image(width: 120, height: 180);
        for (var y = 0; y < 180; y++) {
          for (var x = 0; x < 120; x++) {
            pixels.setPixelRgb(x, y, 40 + x, 50 + y, 180);
          }
        }
        final file = File('${directory.path}/page.png')
          ..writeAsBytesSync(img.encodePng(pixels));
        var binding = ReaderViewportBinding();
        final imageWork = ImageWork();
        var ready = 0;
        var collected = 0;
        final reports = <(bool, bool)>[];
        final reads = <ReaderImageAddress>[];
        late ReaderGalleryData data;
        final navigation = ReaderController(
          pageCount: () => data.totalPages,
          chapterCount: () => 1,
          animationEnabled: () => false,
          viewport: () => binding.current,
          onChanged: () {},
          onPageChanged: () {},
          onError: (error, stack) => fail('$error'),
        )..replaceChapterImages(List.filled(30, 'file://${file.path}'));

        ReaderGalleryData inputs({
          int imagesPerPage = 1,
          bool collect = false,
          bool? reverse,
        }) => ReaderGalleryData(
          content: navigation.content,
          layout: ReaderPageLayout(
            imagesPerPage: imagesPerPage,
            singleImageOnFirstPage: false,
          ),
          vertical: direction == 'vertical',
          reverse: reverse ?? direction == 'rtl',
          commentsAtEnd: true,
          firstChapter: true,
          lastChapter: true,
          preloadCount: 0,
          doubleTapCollect: collect,
          centerLongPressZoom: true,
          pageAnimation: false,
          sourceKey: null,
          comicId: 'book',
          chapterId: 'chapter',
        );
        data = inputs();
        Widget build() => MaterialApp(
          theme: ThemeData(
            brightness: direction == 'rtl' ? Brightness.dark : Brightness.light,
          ),
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: RepaintBoundary(
              key: repaint,
              child: ReaderGalleryView(
                imageWork: imageWork,
                data: data,
                navigation: navigation,
                onViewportChanged: binding.update,
                onReady: () => ready++,
                onPageReported: (comments, refresh) =>
                    reports.add((comments, refresh)),
                onChapterChanged: () => fail('Only one chapter exists'),
                onCollectImage: () => collected++,
                readerSize: () => size,
                readImage: (address) async {
                  reads.add(address);
                  return file.readAsBytesSync();
                },
                commentsBuilder: (_) => const Text('Injected comments'),
              ),
            ),
          ),
        );
        try {
          await tester.pumpWidget(build());
          expect(ready, 1);
          final gallery = tester.widget<PageView>(find.byType(PageView));
          final state = tester.state<GalleryModeState>(
            find.byType(ReaderGalleryView),
          );
          final pages = state.controller;
          final closed = <PhotoViewController, bool>{};
          void observeControllers() {
            for (final controller in state.photoViewControllers.values) {
              if (closed.containsKey(controller)) continue;
              closed[controller] = false;
              controller.outputStateStream.listen(
                (_) {},
                onDone: () => closed[controller] = true,
              );
            }
          }

          Future<void> readyImage() async {
            for (var i = 0; i < 100 && !state.autoReadingReady; i++) {
              await tester.pump(const Duration(milliseconds: 20));
              await tester.runAsync(() => pumpEventQueue());
            }
            expect(state.autoReadingReady, true);
          }

          Future<void> capture(int imagesPerPage) async {
            final output = Platform.environment['PHOTO_LIFECYCLE_QA_DIR'];
            if (output == null) return;
            await tester.pump();
            await tester.runAsync(() async {
              final boundary =
                  repaint.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final target = File('$output/$direction-$imagesPerPage.png');
                await target.parent.create(recursive: true);
                await target.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }

          Future<void> checkSelection(int count) async {
            final visible =
                state.imageStates.keys
                    .whereType<ComicImageState>()
                    .where((image) => image.visibleInReader)
                    .toList()
                  ..sort((a, b) {
                    final first = tester.getCenter(find.byWidget(a.widget));
                    final second = tester.getCenter(find.byWidget(b.widget));
                    return data.vertical
                        ? first.dy.compareTo(second.dy)
                        : first.dx.compareTo(second.dx);
                  });
            expect(visible, hasLength(count));
            final ordered = data.reverse ? visible.reversed.toList() : visible;
            final start = state.currentImageRange!.$1;
            for (var i = 0; i < count; i++) {
              final point = tester.getCenter(find.byWidget(ordered[i].widget));
              final picker = ReaderImagePicker(
                current: () => ReaderImagePickContext(
                  viewport: state,
                  images: data.images,
                  chapter: 1,
                ),
                selectPosition: () async => point,
              );
              expect((await picker.pick())?.index, start + i);
              picker.dispose();
              await tester.runAsync(() => state.getImageByOffset(point));
              expect(reads.last.imageKey, data.images[start + i]);
              expect(reads.last.sourceKey, isNull);
              expect(reads.last.comicId, 'book');
              expect(reads.last.chapterId, 'chapter');
            }
          }

          observeControllers();
          expect(gallery.reverse, direction == 'rtl');
          expect(
            gallery.scrollDirection,
            direction == 'vertical' ? Axis.vertical : Axis.horizontal,
          );
          expect(binding.current!.currentImageRange, (0, 1));
          await readyImage();
          await capture(1);
          final firstPhoto = state.photoViewControllers[1]!;
          final originalScale = firstPhoto.getInitialScale!()!;
          firstPhoto.scale = originalScale * 1.5;
          final turning = state.animateToPage(2);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          expect(closed[firstPhoto], false);
          await tester.pumpAndSettle();
          await turning;
          navigation.toPage(1, animated: false);
          await tester.pump();
          await readyImage();
          expect(state.photoViewControllers[1], isNot(same(firstPhoto)));
          expect(
            state.photoViewControllers[1]!.scale,
            closeTo(originalScale, .01),
          );
          observeControllers();

          navigation.toPage(2, animated: false);
          await tester.pump();
          observeControllers();
          expect(binding.current!.currentImageRange, (1, 2));
          expect(binding.current!.getImageIndexByOffset(Offset.zero), 1);
          for (var index = 3; index <= 20; index++) {
            navigation.toPage(index, animated: false);
            await tester.pump();
            await tester.pump();
            observeControllers();
            expect(state.photoViewControllers.length, lessThanOrEqualTo(3));
            expect(
              closed.values.where((done) => !done).length,
              lessThanOrEqualTo(3),
            );
          }
          navigation.toPage(2, animated: false);
          await tester.pump();
          observeControllers();

          final previousOwner = binding;
          final retained = binding.current;
          binding = ReaderViewportBinding();
          await tester.pumpWidget(build());
          expect(previousOwner.current, isNull);
          expect(binding.current, same(retained));
          data = inputs(imagesPerPage: 2, collect: true);
          await tester.pumpWidget(build());
          expect(binding.current!.currentImageRange, (2, 4));
          observeControllers();
          binding.current!.handleDoubleTap(Offset.zero);
          expect(collected, 1);
          await readyImage();
          await capture(2);
          await checkSelection(2);
          data = inputs(imagesPerPage: 3, collect: true);
          await tester.pumpWidget(build());
          observeControllers();
          await readyImage();
          await capture(3);
          await checkSelection(3);
          data = inputs(imagesPerPage: 3, reverse: !data.reverse);
          await tester.pumpWidget(build());
          await readyImage();
          await checkSelection(3);
          data = inputs(imagesPerPage: 3);
          await tester.pumpWidget(build());
          await readyImage();
          await checkSelection(3);
          navigation.toPage(data.totalPages, animated: false);
          await tester.pump();
          expect(find.text('Injected comments'), findsOneWidget);
          expect(reports.last, (true, false));
          state.fingers = 1;
          state.handleLongPressDown(Offset.zero);
          state.handleLongPressUp(Offset.zero);

          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(binding.current, isNull);
          expect(state.photoViewControllers, isEmpty);
          expect(closed.values, everyElement(true));
          expect(() => pages.addListener(() {}), throwsFlutterError);
          state.handleDoubleTap(Offset.zero);
          expect(collected, 1);
          final readCount = reads.length;
          expect(await state.getImageByOffset(Offset.zero), isNull);
          expect(state.getImageIndexByOffset(Offset.zero), isNull);
          expect(reads, hasLength(readCount));
          expect(state.imageStates, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox());
          final closingImages = imageWork.dispose();
          var imagesClosed = false;
          unawaited(
            closingImages.then<void>(
              (_) => imagesClosed = true,
              onError: (Object error, StackTrace stack) => imagesClosed = true,
            ),
          );
          // Real file/native callbacks and their fake-async continuations must
          // both advance; only the owner's completion permits deleting files.
          while (!imagesClosed) {
            await tester.pump();
            await tester.runAsync(() => pumpEventQueue());
          }
          navigation.dispose();
          await tester.runAsync(() async {
            await closingImages;
            directory.deleteSync(recursive: true);
          });
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
