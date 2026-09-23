import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';

void main() {
  test(
    'entry class accepts indentation, multiline extends and helper classes',
    () {
      expect(
        sourceClassName(
          'class Helper {}\n  class Demo\n extends ComicSource {}',
        ),
        'Demo',
      );
      expect(
        sourceClassName('\uFEFFclass Demo extends ComicSource {}'),
        'Demo',
      );
      expect(
        () => sourceClassName('<html>Error</html>'),
        throwsA(
          isA<ComicSourceParseException>().having(
            (e) => e.message,
            'actionable error',
            contains('extending ComicSource'),
          ),
        ),
      );
    },
  );
}
