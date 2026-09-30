import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera_next/features/reader/continuous_data.dart';
import 'package:venera_next/features/reader/continuous_view.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';

void main() {
  for (final mode in ['ltr', 'rtl', 'vertical', 'waterfall']) {
    testWidgets('continuous view mounts with explicit dependencies ($mode)', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync(
        'continuous-input-',
      );
      final file = File('${directory.path}/page.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 80)));
      final imageKey = 'file://${file.path}';
      ReaderImageViewController? viewport;
      var collected = 0;
      final loads = <int>[];
      final lifecycle = <bool>[];
      final navigation = ReaderController(
        pageCount: () => 3,
        chapterCount: () => 2,
        animationEnabled: () => false,
        viewport: () => viewport,
        onChanged: () {},
        onPageChanged: () {},
        onError: (error, stack) => fail('$error'),
      )..replaceChapterImages(List.filled(3, imageKey));
      var margin = 0.0;
      Widget build() => MaterialApp(
        home: ReaderContinuousView(
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
          onViewportChanged: (value, attached) {
            if (attached) {
              viewport = value;
            } else if (identical(viewport, value)) {
              viewport = null;
            }
          },
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
        viewport!.handleDoubleTap(Offset.zero);
        expect(collected, 1);
        margin = 10;
        await tester.pumpWidget(build());
        final photo = tester.widget<PhotoView>(find.byType(PhotoView));
        expect(
          photo.childSize!.width,
          mode == 'ltr' || mode == 'rtl' ? 800 : 640,
        );
        if (mode == 'waterfall') {
          expect(viewport!.toChapter(2), true);
          for (var i = 0; i < 4; i++) {
            await tester.pump();
          }
          expect(loads, contains(2));
          expect(navigation.state.chapter, 2);
          expect(navigation.content.images, [imageKey]);
          expect(lifecycle.last, false);
        } else {
          expect(viewport!.toChapter(2), false);
          expect(loads, isEmpty);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        expect(viewport, isNull);
      } finally {
        navigation.dispose();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          directory.deleteSync(recursive: true);
        });
      }
    });
  }
}
