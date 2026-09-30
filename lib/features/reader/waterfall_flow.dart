import 'image_position.dart';

class WaterfallImageRef {
  final ReaderImagePosition position;
  final String imageKey;
  final bool isFirstInSegment;

  const WaterfallImageRef({
    required this.position,
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
          position: ReaderImagePosition(
            chapter: segment.chapter,
            imageNumber: remaining,
            chapterId: segment.eid,
          ),
          imageKey: segment.images[remaining - 1],
          isFirstInSegment: remaining == 1,
        );
      }
      remaining -= segment.images.length;
    }
    return null;
  }

  int? imageIndexOf(ReaderImagePosition position) {
    if (position.imageNumber <= 0) return null;
    var index = 1;
    for (var segment in _segments) {
      if (segment.chapter == position.chapter) {
        if (segment.eid != position.chapterId ||
            position.imageNumber > segment.images.length) {
          return null;
        }
        return index + position.imageNumber - 1;
      }
      index += segment.images.length;
    }
    return null;
  }

  bool shouldLoadAfter({
    required int current,
    required int threshold,
    required int maxChapter,
  }) {
    if (_segments.isEmpty) return false;
    if (imageCount - current >= threshold) return false;
    return _segments.last.chapter < maxChapter;
  }

  bool shouldLoadBefore({required int current, required int threshold}) {
    if (_segments.isEmpty) return false;
    if (current > threshold) return false;
    return _segments.first.chapter > 1;
  }

  void addAfter(WaterfallChapterSegment segment) {
    if (_segments.any((item) => item.chapter == segment.chapter)) return;
    _segments.add(segment);
    _segments.sort((a, b) => a.chapter.compareTo(b.chapter));
  }

  int addBefore(WaterfallChapterSegment segment) {
    if (_segments.any((item) => item.chapter == segment.chapter)) return 0;
    _segments.add(segment);
    _segments.sort((a, b) => a.chapter.compareTo(b.chapter));
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
