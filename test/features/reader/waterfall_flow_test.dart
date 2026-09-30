import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/features/reader/image_position.dart';

WaterfallChapterSegment segment(int chapter, int count) {
  return WaterfallChapterSegment(
    chapter: chapter,
    eid: 'ep-$chapter',
    images: List.generate(count, (index) => 'c$chapter-p${index + 1}'),
  );
}

void main() {
  group('WaterfallChapterFlow', () {
    test(
      'source positions survive prepending and round trip to viewport indices',
      () {
        final flow = WaterfallChapterFlow(
          segments: [segment(3, 4), segment(4, 3)],
        );
        final anchor = flow.imageRefAt(6)!.position;
        expect(anchor.chapter, 4);
        expect(anchor.chapterId, 'ep-4');
        expect(anchor.imageNumber, 2);
        flow.addBefore(segment(2, 5));
        expect(flow.imageIndexOf(anchor), 11);
        for (var index = 1; index <= flow.imageCount; index++) {
          expect(flow.imageIndexOf(flow.imageRefAt(index)!.position), index);
        }
        expect(anchor.imageNumber, 2);
      },
    );

    test('a position from a different source chapter ID is not reused', () {
      final flow = WaterfallChapterFlow(segments: [segment(3, 4)]);
      expect(
        flow.imageIndexOf(
          const ReaderImagePosition(
            chapter: 3,
            chapterId: 'old-ep-3',
            imageNumber: 2,
          ),
        ),
        isNull,
      );
      expect(
        flow.imageIndexOf(
          const ReaderImagePosition(
            chapter: 3,
            chapterId: 'ep-3',
            imageNumber: 2,
          ),
        ),
        2,
      );
    });

    test('maps global image index to chapter and page', () {
      final flow = WaterfallChapterFlow(
        segments: [segment(2, 3), segment(3, 2)],
      );

      expect(flow.imageCount, 5);
      expect(flow.imageRefAt(0), isNull);
      expect(flow.imageRefAt(1)!.position.chapter, 2);
      expect(flow.imageRefAt(1)!.position.imageNumber, 1);
      expect(flow.imageRefAt(1)!.isFirstInSegment, isTrue);
      expect(flow.imageRefAt(3)!.imageKey, 'c2-p3');
      expect(flow.imageRefAt(4)!.position.chapter, 3);
      expect(flow.imageRefAt(4)!.position.imageNumber, 1);
      expect(flow.imageRefAt(4)!.isFirstInSegment, isTrue);
      expect(flow.imageRefAt(5)!.imageKey, 'c3-p2');
      expect(flow.imageRefAt(6), isNull);
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 2, chapterId: 'ep-2', imageNumber: 1),
        ),
        1,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 2, chapterId: 'ep-2', imageNumber: 3),
        ),
        3,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 3, chapterId: 'ep-3', imageNumber: 1),
        ),
        4,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 3, chapterId: 'ep-3', imageNumber: 2),
        ),
        5,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 3, chapterId: 'ep-3', imageNumber: 3),
        ),
        isNull,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 4, chapterId: 'ep-4', imageNumber: 1),
        ),
        isNull,
      );
    });

    test('detects when next chapter should be loaded', () {
      final flow = WaterfallChapterFlow(segments: [segment(2, 5)]);

      expect(
        flow.shouldLoadAfter(current: 2, threshold: 2, maxChapter: 3),
        isFalse,
      );
      expect(
        flow.shouldLoadAfter(current: 4, threshold: 2, maxChapter: 3),
        isTrue,
      );
      expect(
        flow.shouldLoadAfter(current: 4, threshold: 2, maxChapter: 2),
        isFalse,
      );
    });

    test('detects when previous chapter should be loaded', () {
      final flow = WaterfallChapterFlow(segments: [segment(2, 5)]);

      expect(flow.shouldLoadBefore(current: 3, threshold: 2), isFalse);
      expect(flow.shouldLoadBefore(current: 2, threshold: 2), isTrue);

      final firstChapterFlow = WaterfallChapterFlow(segments: [segment(1, 5)]);
      expect(
        firstChapterFlow.shouldLoadBefore(current: 1, threshold: 2),
        isFalse,
      );
    });

    test('inserts previous chapter and keeps index offset computable', () {
      final flow = WaterfallChapterFlow(segments: [segment(3, 2)]);

      final insertedCount = flow.addBefore(segment(2, 4));

      expect(insertedCount, 4);
      expect(flow.firstChapter, 2);
      expect(flow.lastChapter, 3);
      expect(flow.imageRefAt(5)!.position.chapter, 3);
      expect(flow.imageRefAt(5)!.position.imageNumber, 1);
    });

    test(
      'keeps current chapter addressable after previous chapter is inserted',
      () {
        final flow = WaterfallChapterFlow(segments: [segment(98, 3)]);

        final insertedCount = flow.addBefore(segment(97, 5));
        final shiftedCurrentIndex = 1 + insertedCount;

        expect(flow.imageRefAt(shiftedCurrentIndex)!.position.chapter, 98);
        expect(flow.imageRefAt(shiftedCurrentIndex)!.position.imageNumber, 1);
        expect(
          flow.imageIndexOf(
            ReaderImagePosition(
              chapter: 98,
              chapterId: 'ep-98',
              imageNumber: 1,
            ),
          ),
          shiftedCurrentIndex,
        );
      },
    );

    test('resets to an explicit navigation chapter', () {
      final flow = WaterfallChapterFlow(
        segments: [segment(97, 2), segment(98, 3)],
      );

      flow.reset(segment(120, 4));

      expect(flow.segments, hasLength(1));
      expect(flow.firstChapter, 120);
      expect(flow.lastChapter, 120);
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(
            chapter: 120,
            chapterId: 'ep-120',
            imageNumber: 4,
          ),
        ),
        4,
      );
      expect(
        flow.imageIndexOf(
          ReaderImagePosition(chapter: 98, chapterId: 'ep-98', imageNumber: 1),
        ),
        isNull,
      );
    });

    test('ignores duplicate chapters', () {
      final flow = WaterfallChapterFlow(segments: [segment(2, 2)]);

      expect(flow.addBefore(segment(2, 4)), 0);
      flow.addAfter(segment(2, 4));

      expect(flow.imageCount, 2);
      expect(flow.segments, hasLength(1));
    });

    test(
      'resolves top-to-bottom current image as last image at scroll end',
      () {
        expect(
          resolveFlowCurrentImageIndex(
            visibleIndex: 8,
            imageCount: 10,
            isTopToBottom: true,
            isAtScrollEnd: true,
          ),
          10,
        );
        expect(
          resolveFlowCurrentImageIndex(
            visibleIndex: 8,
            imageCount: 10,
            isTopToBottom: true,
            isAtScrollEnd: false,
          ),
          8,
        );
        expect(
          resolveFlowCurrentImageIndex(
            visibleIndex: 8,
            imageCount: 10,
            isTopToBottom: false,
            isAtScrollEnd: true,
          ),
          8,
        );
      },
    );
  });
}
