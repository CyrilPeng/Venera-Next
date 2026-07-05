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
}
