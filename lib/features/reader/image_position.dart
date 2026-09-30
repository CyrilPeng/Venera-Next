/// A source image, independent of grouped display pages and viewport offsets.
/// Chapter and image numbers are one-based; chapter ID is the source identity.
/// Both halves of a split wide image retain this same position in history.
class ReaderImagePosition {
  const ReaderImagePosition({
    required this.chapter,
    required this.chapterId,
    required this.imageNumber,
  });

  final int chapter;
  final String chapterId;
  final int imageNumber;
}

/// Normalized geometry of a displayed slice of one ReaderImagePosition.
/// These offsets describe painting only; they never become history page numbers.
class ReaderImageSlice {
  const ReaderImageSlice({required this.sourceLeft, required this.displayTop});

  final double sourceLeft;
  final double displayTop;
  double get sourceWidth => 0.5;
  double get displayHeight => 0.5;
}

/// Reading order for a wide image stacked vertically (right half first by default).
List<ReaderImageSlice> splitWideImageSlices({required bool invert}) => invert
    ? const [
        ReaderImageSlice(sourceLeft: 0, displayTop: 0),
        ReaderImageSlice(sourceLeft: 0.5, displayTop: 0.5),
      ]
    : const [
        ReaderImageSlice(sourceLeft: 0.5, displayTop: 0),
        ReaderImageSlice(sourceLeft: 0, displayTop: 0.5),
      ];
