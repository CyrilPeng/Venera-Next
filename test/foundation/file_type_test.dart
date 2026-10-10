import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/file_type.dart';

void main() {
  test('uses an image URL extension when the response header is unknown', () {
    final type = detectFileType(const [1, 2, 3], fallbackExtension: '.jpg');

    expect(type.ext, '.jpg');
    expect(type.mime, 'image/jpeg');
  });

  test('does not use a non-image URL extension as an image fallback', () {
    final type = detectFileType(const [1, 2, 3], fallbackExtension: '.html');

    expect(type.ext, '.');
    expect(type.mime, 'application/octet-stream');
  });
}
