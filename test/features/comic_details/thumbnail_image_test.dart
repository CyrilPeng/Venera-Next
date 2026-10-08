import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/thumbnail_image.dart';

void main() {
  test(
    'thumbnail crop preserves full, partial and malformed legacy syntax',
    () {
      expect(ThumbnailImage.parse('https://test/a.png').crop, isNull);
      final full = ThumbnailImage.parse('image@x=1-2&y=3-4');
      expect(full.url, 'image');
      expect(full.crop, (x1: 1.0, x2: 2.0, y1: 3.0, y2: 4.0));
      expect(ThumbnailImage.parse('image@y=3-4&x=5-bad').crop, (
        x1: 5.0,
        x2: null,
        y1: 3.0,
        y2: 4.0,
      ));
      expect(ThumbnailImage.parse('image@x=-1-2&y=3-4').crop, (
        x1: null,
        x2: null,
        y1: null,
        y2: null,
      ));
      expect(ThumbnailImage.parse('image@x=1-2@ignored').crop, (
        x1: 1.0,
        x2: 2.0,
        y1: null,
        y2: null,
      ));
      expect(ThumbnailImage.parse('image@x=1-2&x=7-8').crop, (
        x1: 7.0,
        x2: 8.0,
        y1: null,
        y2: null,
      ));
      expect(ThumbnailImage.parse('image@unrecognized').url, 'image');
    },
  );
}
