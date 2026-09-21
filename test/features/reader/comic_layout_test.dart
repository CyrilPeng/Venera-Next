import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/comic_layout.dart';

void main() {
  group('original image proportions', () {
    final cases = <String, (List<double>, ComicLayout)>{
      'ordinary pages': ([1.4, 1.5, 1.6, 1.3], ComicLayout.paged),
      'long strips at the boundary': ([2.5, 3, 4, 5], ComicLayout.longStrip),
      'page boundaries': ([0.5, 2, 0.5, 2], ComicLayout.paged),
      'eighty percent strips': ([3, 3, 3, 3, 1.5], ComicLayout.longStrip),
      'five of six strips': ([3, 3, 3, 3, 3, 1.5], ComicLayout.longStrip),
      'four of six strips are insufficient': (
        [3, 3, 3, 3, 1, 1],
        ComicLayout.unknown,
      ),
      'mixed pages and strips stay unknown': (
        [1, 1, 1, 1, 3],
        ComicLayout.unknown,
      ),
      'ambiguous proportions': ([2.1, 2.2, 2.3, 2.4], ComicLayout.unknown),
      'too few pages': ([1, 1, 1], ComicLayout.unknown),
      'no pages': ([], ComicLayout.unknown),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        final result = ComicLayoutDetection.fromRatios(entry.value.$1);
        expect(result.layout, entry.value.$2);
        expect(result.sampleCount, entry.value.$1.length);
      });
    }

    test('invalid dimensions never count toward the minimum sample size', () {
      final result = ComicLayoutDetection.fromRatios([
        double.nan,
        double.infinity,
        0,
        -1,
        1.5,
        1.5,
        1.5,
      ]);
      expect(result.layout, ComicLayout.unknown);
      expect(result.sampleCount, 3);
    });
  });
}
