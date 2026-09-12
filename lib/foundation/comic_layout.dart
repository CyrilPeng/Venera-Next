/// The layout of the source images, independent of a reader's navigation mode.
enum ComicLayout {
  unknown,
  paged,
  longStrip;

  static ComicLayout fromKey(Object? key) =>
      values.where((value) => value.name == key).firstOrNull ?? unknown;
}

class ComicLayoutDetection {
  const ComicLayoutDetection(this.layout, this.sampleCount);

  // Bump when the sampling or classification rules change.
  static const version = 1;
  static const maxSamples = 6;
  static const minSamples = 4;

  final ComicLayout layout;
  final int sampleCount;

  /// Ratios are source image height / width, before display transformations.
  factory ComicLayoutDetection.fromRatios(Iterable<double> samples) {
    final ratios = samples.where((r) => r.isFinite && r > 0).toList();
    if (ratios.length < minSamples) {
      return ComicLayoutDetection(ComicLayout.unknown, ratios.length);
    }
    final longImages = ratios.where((r) => r >= 2.5).length;
    final pageImages = ratios.where((r) => r >= 0.5 && r <= 2.0).length;
    final required = (ratios.length * 0.8).ceil();
    final layout = longImages >= required
        ? ComicLayout.longStrip
        : pageImages >= required && longImages == 0
        ? ComicLayout.paged
        : ComicLayout.unknown;
    return ComicLayoutDetection(layout, ratios.length);
  }
}
