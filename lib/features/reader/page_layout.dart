import 'dart:math' as math;

/// Mapping between one-based image numbers and display pages.
/// Image ranges use zero-based, end-exclusive indices for List.sublist.
class ReaderPageLayout {
  const ReaderPageLayout({
    required this.imagesPerPage,
    required this.singleImageOnFirstPage,
  }) : assert(imagesPerPage > 0);

  final int imagesPerPage;
  final bool singleImageOnFirstPage;

  /// Null means images have not loaded; preserve the loading placeholder page.
  int pageCount(int? imageCount) {
    if (imageCount == null) return 1;
    return singleImageOnFirstPage
        ? 1 + ((imageCount - 1) / imagesPerPage).ceil()
        : (imageCount / imagesPerPage).ceil();
  }

  int pageForImage(int imageNumber) {
    if (imagesPerPage == 1) return imageNumber;
    return singleImageOnFirstPage
        ? ((imageNumber - 1) / imagesPerPage).ceil() + 1
        : (imageNumber / imagesPerPage).ceil();
  }

  int firstImageOnPage(int page) {
    if (singleImageOnFirstPage && page != 1) {
      return (page - 2) * imagesPerPage + 2;
    }
    return (page - 1) * imagesPerPage + 1;
  }

  (int start, int end) imageRange(int page, int imageCount) {
    if (singleImageOnFirstPage && page == 1) return (0, 1);
    final start = firstImageOnPage(page) - 1;
    return (start, math.min(start + imagesPerPage, imageCount));
  }

  /// Finishing the last display page (or its comments page) marks the last image.
  int historyImage(int page, int imageCount) =>
      page >= pageCount(imageCount) ? imageCount : firstImageOnPage(page);

  /// Keep the first image visible across layouts, or preserve the trailing
  /// comments page. This does not change chapter IDs or waterfall segments.
  int remapPage(int page, ReaderPageLayout target, {required int? imageCount}) {
    final targetCount = target.pageCount(imageCount);
    if (page > pageCount(imageCount)) return targetCount + 1;
    return target
        .pageForImage(firstImageOnPage(page))
        .clamp(1, math.max(1, targetCount));
  }
}
