/// Legacy source thumbnail crop syntax, including partially parsed coordinates.
class ThumbnailImage {
  const ThumbnailImage(this.url, this.crop);
  final String url;
  final ({double? x1, double? x2, double? y1, double? y2})? crop;

  factory ThumbnailImage.parse(String value) {
    if (!value.contains('@')) return ThumbnailImage(value, null);
    final parts = value.split('@');
    double? x1, x2, y1, y2;
    try {
      for (final part in parts[1].split('&')) {
        if (part.startsWith('x')) {
          final range = part.split('=')[1].split('-');
          x1 = double.parse(range[0]);
          x2 = double.parse(range[1]);
        }
        if (part.startsWith('y')) {
          final range = part.split('=')[1].split('-');
          y1 = double.parse(range[0]);
          y2 = double.parse(range[1]);
        }
      }
    } catch (_) {
      // Existing sources can leave a partially specified crop.
    }
    return ThumbnailImage(parts[0], (x1: x1, x2: x2, y1: y1, y2: y2));
  }
}
