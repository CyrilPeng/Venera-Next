import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/image_position.dart';

void main() {
  group('dual page split helpers', () {
    test('normalized slices cover source and display once in either order', () {
      for (final invert in [false, true]) {
        final slices = splitWideImageSlices(invert: invert);
        expect(slices.map((s) => s.sourceLeft).toSet(), {0, 0.5});
        expect(slices.map((s) => s.displayTop), [0, 0.5]);
        expect(slices.fold<double>(0, (sum, s) => sum + s.sourceWidth), 1);
        expect(slices.fold<double>(0, (sum, s) => sum + s.displayHeight), 1);
        expect(slices.first.sourceLeft, invert ? 0 : 0.5);
      }
    });

    test('detects wide images only', () {
      expect(shouldSplitWideImage(const Size(1200, 800)), isTrue);
      expect(shouldSplitWideImage(const Size(800, 1200)), isFalse);
      expect(shouldSplitWideImage(const Size(1000, 1000)), isFalse);
    });

    test('uses vertical display size for wide images', () {
      expect(
        splitWideImageDisplaySize(const Size(1200, 800)),
        const Size(600, 1600),
      );
      expect(
        splitWideImageDisplaySize(const Size(800, 1200)),
        const Size(800, 1200),
      );
    });

    test('puts right half first by default', () {
      expect(splitWideImageSourceRects(const Size(1200, 800), invert: false), [
        const Rect.fromLTWH(600, 0, 600, 800),
        const Rect.fromLTWH(0, 0, 600, 800),
      ]);
    });

    test('swaps split order when inverted', () {
      expect(splitWideImageSourceRects(const Size(1200, 800), invert: true), [
        const Rect.fromLTWH(0, 0, 600, 800),
        const Rect.fromLTWH(600, 0, 600, 800),
      ]);
    });
  });
}
