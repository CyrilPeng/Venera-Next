import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';

void main() {
  test(
    'read-only comic info namespaces are not treated as searchable tags',
    () {
      expect(isReadOnlyComicInfoNamespace('views'), isTrue);
      expect(isReadOnlyComicInfoNamespace('浏览量'), isTrue);
      expect(isReadOnlyComicInfoNamespace('last update'), isTrue);

      expect(isReadOnlyComicInfoNamespace('artist'), isFalse);
      expect(isReadOnlyComicInfoNamespace('language'), isFalse);

      expect(isAuthorNamespace('author'), isTrue);
      expect(isAuthorNamespace('artist'), isTrue);
      expect(isAuthorNamespace('language'), isFalse);
    },
  );
}
