import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_next/features/reader/continuous_data.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';

void main() {
  for (final mode in ['ltr', 'rtl', 'vertical', 'waterfall']) {
    testWidgets(
      'continuous view mounts with explicit dependencies ($mode)',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'continuous-input-',
        );
        final file = File('${directory.path}/page.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 80)));
        final imageKey = 'file://${file.path}';
        var binding = ReaderViewportBinding();
        final imageWork = ImageWork();
        var collected = 0;
        final loads = <int>[];
        final lifecycle = <bool>[];
        final navigation = ReaderController(
          pageCount: () => 3,
          chapterCount: () => 2,
          animationEnabled: () => false,
          viewport: () => binding.current,
          onChanged: () {},
          onPageChanged: () {},
          onError: (error, stack) => fail('$error'),
        )..replaceChapterImages(List.filled(3, imageKey));
        var margin = 0.0;
        Widget build() => MaterialApp(
          home: ReaderContinuousView(
            imageWork: imageWork,
            data: ReaderContinuousData(
              vertical: mode == 'vertical' || mode == 'waterfall',
              reverse: mode == 'rtl',
              crossChapter: mode == 'waterfall',
              firstChapter: true,
              lastChapter: false,
              maxChapter: 2,
              preloadCount: 0,
              splitWideImages: false,
              invertSplit: false,
              scrollSpeed: 1,
              limitImageWidth: false,
              sideMargin: margin,
              doubleTapCollect: true,
              centerLongPressZoom: true,
              sourceKey: null,
              comicId: 'book',
            ),
            navigation: navigation,
            loadChapter: (chapter, scope) async {
              scope.check();
              loads.add(chapter);
              return [imageKey];
            },
            chapterId: (chapter) => 'id-$chapter',
            chapterTitle: (chapter) => 'Title $chapter',
            onViewportChanged: binding.update,
            onUpdate: () {},
            onFloatingButton: (_) {},
            onCollectImage: () => collected++,
            onActiveChapterChanged: () {},
            onContentLoading: lifecycle.add,
            onPreviousError: (error, stack) => fail('$error'),
            onNavigationError: (chapter, error, stack) => fail('$error'),
            readerSize: () => const Size(800, 600),
            readImage: (_) async => file.readAsBytesSync(),
          ),
        );
        try {
          await tester.pumpWidget(build());
          await tester.pump();
          final list = tester.widget<ScrollablePositionedList>(
            find.byType(ScrollablePositionedList),
          );
          expect(list.reverse, mode == 'rtl');
          expect(
            list.scrollDirection,
            mode == 'ltr' || mode == 'rtl' ? Axis.horizontal : Axis.vertical,
          );
          binding.current!.handleDoubleTap(Offset.zero);
          expect(collected, 1);
          final previousOwner = binding;
          final retained = binding.current;
          binding = ReaderViewportBinding();
          await tester.pumpWidget(build());
          expect(previousOwner.current, isNull);
          expect(binding.current, same(retained));
          margin = 10;
          await tester.pumpWidget(build());
          final photo = tester.widget<PhotoView>(find.byType(PhotoView));
          final state = tester.state<ContinuousModeState>(
            find.byType(ReaderContinuousView),
          );
          var photoClosed = false;
          state.photoViewController.outputStateStream.listen(
            (_) {},
            onDone: () => photoClosed = true,
          );
          expect(
            photo.childSize!.width,
            mode == 'ltr' || mode == 'rtl' ? 800 : 640,
          );
          if (mode == 'waterfall') {
            expect(binding.current!.toChapter(2), true);
            for (var i = 0; i < 4; i++) {
              await tester.pump();
            }
            expect(loads, contains(2));
            expect(navigation.state.chapter, 2);
            expect(navigation.content.images, [imageKey]);
            expect(lifecycle.last, false);
          } else {
            expect(binding.current!.toChapter(2), false);
            expect(loads, isEmpty);
          }
          for (var i = 0; i < 80; i++) {
            await tester.pump(const Duration(milliseconds: 10));
            await tester.runAsync(() => pumpEventQueue());
            if (state.scrollController.hasClients &&
                state.scrollController.position.maxScrollExtent > 0) {
              break;
            }
          }
          expect(
            state.scrollController.position.maxScrollExtent,
            greaterThan(0),
          );
          state.smoothTo(200);
          await tester.pump(const Duration(milliseconds: 20));
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
          expect(binding.current, isNull);
          expect(photoClosed, true);
          state.handleDoubleTap(Offset.zero);
          state.smoothTo(100);
          expect(collected, 1);
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
