import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';

void main() {
  test(
    'read-only comic info namespaces are not treated as searchable tags',
    () {
      expect(isReadOnlyComicInfoNamespaceForTesting('views'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('浏览量'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('last update'), isTrue);

      expect(isReadOnlyComicInfoNamespaceForTesting('artist'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('language'), isFalse);
    },
  );
}
