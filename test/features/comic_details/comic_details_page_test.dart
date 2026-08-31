import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';

void main() {
  test('Bangumi progress action follows favorite action', () {
    final source = File(
      'lib/features/comic_details/comic_page.dart',
    ).readAsStringSync();
    final favorite = source.indexOf("Key('comic-detail-favorite')");
    final progress = source.indexOf("Key('comic-detail-progress')");
    expect(favorite, greaterThanOrEqualTo(0));
    expect(progress, greaterThan(favorite));
  });

  test(
    'read-only comic info namespaces are not treated as searchable tags',
    () {
      expect(isReadOnlyComicInfoNamespaceForTesting('views'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('浏览量'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('last update'), isTrue);

      expect(isReadOnlyComicInfoNamespaceForTesting('artist'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('language'), isFalse);

      expect(isAuthorNamespace('author'), isTrue);
      expect(isAuthorNamespace('artist'), isTrue);
      expect(isAuthorNamespace('language'), isFalse);
    },
  );
}
