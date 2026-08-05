import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/local_comics/import_export/import_export.dart';

void main() {
  group('PDF import rendering', () {
    test('uses three times the PDF point size below the edge limit', () {
      final size = calculatePdfRenderSize(612, 792);

      expect(size.width, 1836);
      expect(size.height, 2376);
    });

    test('caps the longest edge while preserving the aspect ratio', () {
      final size = calculatePdfRenderSize(2000, 1000);

      expect(size.width, 3000);
      expect(size.height, 1500);
    });

    test('rejects invalid page dimensions', () {
      expect(
        () => calculatePdfRenderSize(0, 100),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
