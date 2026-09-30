/// Settings and comic identity captured for one continuous-view build.
/// Active chapter/content remain in the injected navigation controller.
class ReaderContinuousData {
  const ReaderContinuousData({
    required this.vertical,
    required this.reverse,
    required this.crossChapter,
    required this.firstChapter,
    required this.lastChapter,
    required this.maxChapter,
    required this.preloadCount,
    required this.splitWideImages,
    required this.invertSplit,
    required this.scrollSpeed,
    required this.limitImageWidth,
    required this.sideMargin,
    required this.doubleTapCollect,
    required this.centerLongPressZoom,
    required this.sourceKey,
    required this.comicId,
  });

  final bool vertical;
  final bool reverse;
  final bool crossChapter;
  final bool firstChapter;
  final bool lastChapter;
  final int maxChapter;
  final int preloadCount;
  final bool splitWideImages;
  final bool invertSplit;
  final double scrollSpeed;
  final bool limitImageWidth;
  final double sideMargin;
  final bool doubleTapCollect;
  final bool centerLongPressZoom;
  final String? sourceKey;
  final String comicId;
}
