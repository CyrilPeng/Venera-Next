import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/reader.dart';

WaterfallChapterSegment segment(int chapter, int count) {
  return WaterfallChapterSegment(
    chapter: chapter,
    eid: 'ep-$chapter',
    images: List.generate(count, (index) => 'c$chapter-p${index + 1}'),
  );
}

void main() {
  group('WaterfallChapterFlow', () {
    test('maps global image index to chapter and page', () {
      final flow = WaterfallChapterFlow(
        segments: [segment(2, 3), segment(3, 2)],
      );

      expect(flow.imageCount, 5);
      expect(flow.imageRefAt(0), isNull);
      expect(flow.imageRefAt(1)!.chapter, 2);
      expect(flow.imageRefAt(1)!.page, 1);
      expect(flow.imageRefAt(1)!.isFirstInSegment, isTrue);
      expect(flow.imageRefAt(3)!.imageKey, 'c2-p3');
      expect(flow.imageRefAt(4)!.chapter, 3);
      expect(flow.imageRefAt(4)!.page, 1);
      expect(flow.imageRefAt(4)!.isFirstInSegment, isTrue);
      expect(flow.imageRefAt(5)!.imageKey, 'c3-p2');
      expect(flow.imageRefAt(6), isNull);
      expect(flow.imageIndexOf(chapter: 2, page: 1), 1);
      expect(flow.imageIndexOf(chapter: 2, page: 3), 3);
      expect(flow.imageIndexOf(chapter: 3, page: 1), 4);
      expect(flow.imageIndexOf(chapter: 3, page: 2), 5);
      expect(flow.imageIndexOf(chapter: 3, page: 3), isNull);
      expect(flow.imageIndexOf(chapter: 4, page: 1), isNull);
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
      expect(flow.imageRefAt(5)!.chapter, 3);
      expect(flow.imageRefAt(5)!.page, 1);
    });

    test(
      'keeps current chapter addressable after previous chapter is inserted',
      () {
        final flow = WaterfallChapterFlow(segments: [segment(98, 3)]);

        final insertedCount = flow.addBefore(segment(97, 5));
        final shiftedCurrentIndex = 1 + insertedCount;

        expect(flow.imageRefAt(shiftedCurrentIndex)!.chapter, 98);
        expect(flow.imageRefAt(shiftedCurrentIndex)!.page, 1);
        expect(flow.imageIndexOf(chapter: 98, page: 1), shiftedCurrentIndex);
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
      expect(flow.imageIndexOf(chapter: 120, page: 4), 4);
      expect(flow.imageIndexOf(chapter: 98, page: 1), isNull);
    });

    test('ignores duplicate chapters', () {
      final flow = WaterfallChapterFlow(segments: [segment(2, 2)]);

      expect(flow.addBefore(segment(2, 4)), 0);
      flow.addAfter(segment(2, 4));

      expect(flow.imageCount, 2);
      expect(flow.segments, hasLength(1));
    });
  });
}
