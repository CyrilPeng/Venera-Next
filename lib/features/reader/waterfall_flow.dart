import 'chapter_order.dart';

class WaterfallImageRef {
  final int chapter;
  final int page;
  final String eid;
  final String imageKey;
  final bool isFirstInSegment;

  const WaterfallImageRef({
    required this.chapter,
    required this.page,
    required this.eid,
    required this.imageKey,
    this.isFirstInSegment = false,
  });
}

class WaterfallChapterSegment {
  final int chapter;
  final String eid;
  final List<String> images;
  final Set<int> cached = {};

  WaterfallChapterSegment({
    required this.chapter,
    required this.eid,
    required this.images,
  });
}

class WaterfallChapterFlow {
  WaterfallChapterFlow({List<WaterfallChapterSegment>? segments}) {
    if (segments != null) {
      _segments.addAll(segments);
    }
  }

  final _segments = <WaterfallChapterSegment>[];

  List<WaterfallChapterSegment> get segments => List.unmodifiable(_segments);

  bool get isEmpty => _segments.isEmpty;

  int get imageCount =>
      _segments.fold(0, (value, segment) => value + segment.images.length);

  int? get firstChapter => _segments.firstOrNull?.chapter;

  int? get lastChapter => _segments.lastOrNull?.chapter;

  WaterfallChapterSegment? segmentOfChapter(int chapter) {
    for (var segment in _segments) {
      if (segment.chapter == chapter) return segment;
    }
    return null;
  }

  WaterfallImageRef? imageRefAt(int index) {
    if (index <= 0) return null;
    var remaining = index;
    for (var segment in _segments) {
      if (remaining <= segment.images.length) {
        return WaterfallImageRef(
          chapter: segment.chapter,
          page: remaining,
          eid: segment.eid,
          imageKey: segment.images[remaining - 1],
          isFirstInSegment: remaining == 1,
        );
      }
      remaining -= segment.images.length;
    }
    return null;
  }

  int? imageIndexOf({required int chapter, required int page}) {
    if (page <= 0) return null;
    var index = 1;
    for (var segment in _segments) {
      if (segment.chapter == chapter) {
        if (page > segment.images.length) return null;
        return index + page - 1;
      }
      index += segment.images.length;
    }
    return null;
  }

  bool shouldLoadAfter({
    required int current,
    required int threshold,
    required ChapterReadingOrder order,
  }) {
    if (_segments.isEmpty) return false;
    if (imageCount - current >= threshold) return false;
    return order.next(_segments.last.chapter) != null;
  }

  bool shouldLoadBefore({
    required int current,
    required int threshold,
    required ChapterReadingOrder order,
  }) {
    if (_segments.isEmpty) return false;
    if (current > threshold) return false;
    return order.previous(_segments.first.chapter) != null;
  }

  void addAfter(WaterfallChapterSegment segment) {
    if (_segments.any((item) => item.chapter == segment.chapter)) return;
    _segments.add(segment);
  }

  int addBefore(WaterfallChapterSegment segment) {
    if (_segments.any((item) => item.chapter == segment.chapter)) return 0;
    _segments.insert(0, segment);
    return segment.images.length;
  }

  void reset(WaterfallChapterSegment segment) {
    _segments
      ..clear()
      ..add(segment);
  }
}

int resolveFlowCurrentImageIndex({
  required int visibleIndex,
  required int imageCount,
  required bool isTopToBottom,
  required bool isAtScrollEnd,
}) {
  if (imageCount <= 0) return 1;
  if (isTopToBottom && isAtScrollEnd) return imageCount;
  return visibleIndex.clamp(1, imageCount);
}
