import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera_next/features/reader/gallery_data.dart';
import 'package:venera_next/features/reader/gallery_view.dart';
import 'package:venera_next/features/reader/page_layout.dart';
import 'package:venera_next/features/reader/reader_controller.dart';
import 'package:venera_next/features/reader/reader_viewport.dart';

void main() {
  for (final direction in ['ltr', 'rtl', 'vertical']) {
    testWidgets(
      'standalone gallery uses injected inputs and actions ($direction)',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('gallery-input-');
        final file = File('${directory.path}/page.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 20, height: 30)));
        var binding = ReaderViewportBinding();
        var ready = 0;
        var collected = 0;
        final reports = <(bool, bool)>[];
        late ReaderGalleryData data;
        final navigation = ReaderController(
          pageCount: () => data.totalPages,
          chapterCount: () => 1,
          animationEnabled: () => false,
          viewport: () => binding.current,
          onChanged: () {},
          onPageChanged: () {},
          onError: (error, stack) => fail('$error'),
        )..replaceChapterImages(List.filled(3, 'file://${file.path}'));

        ReaderGalleryData inputs({
          int imagesPerPage = 1,
          bool collect = false,
        }) => ReaderGalleryData(
          content: navigation.content,
          layout: ReaderPageLayout(
            imagesPerPage: imagesPerPage,
            singleImageOnFirstPage: false,
          ),
          vertical: direction == 'vertical',
          reverse: direction == 'rtl',
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
          home: ReaderGalleryView(
            data: data,
            navigation: navigation,
            onViewportChanged: binding.update,
            onReady: () => ready++,
            onPageReported: (comments, refresh) =>
                reports.add((comments, refresh)),
            onChapterChanged: () => fail('Only one chapter exists'),
            onCollectImage: () => collected++,
            readerSize: () => const Size(800, 600),
            readImage: (key) async => file.readAsBytesSync(),
            commentsBuilder: (_) => const Text('Injected comments'),
          ),
        );
        try {
          await tester.pumpWidget(build());
          expect(ready, 1);
          final gallery = tester.widget<PhotoViewGallery>(
            find.byType(PhotoViewGallery),
          );
          expect(gallery.reverse, direction == 'rtl');
          expect(
            gallery.scrollDirection,
            direction == 'vertical' ? Axis.vertical : Axis.horizontal,
          );
          expect(binding.current!.currentImageRange, (0, 1));

          navigation.toPage(2, animated: false);
          await tester.pump();
          expect(binding.current!.currentImageRange, (1, 2));
          expect(
            binding.current!.getImageKeyByOffset(Offset.zero),
            'file://${file.path}',
          );

          final previousOwner = binding;
          final retained = binding.current;
          binding = ReaderViewportBinding();
          await tester.pumpWidget(build());
          expect(previousOwner.current, isNull);
          expect(binding.current, same(retained));
          data = inputs(imagesPerPage: 2, collect: true);
          await tester.pumpWidget(build());
          expect(binding.current!.currentImageRange, (2, 3));
          binding.current!.handleDoubleTap(Offset.zero);
          expect(collected, 1);
          navigation.toPage(data.totalPages, animated: false);
          await tester.pump();
          expect(find.text('Injected comments'), findsOneWidget);
          expect(reports.last, (true, false));

          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(binding.current, isNull);
        } finally {
          navigation.dispose();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            directory.deleteSync(recursive: true);
          });
        }
      },
    );
  }
}
