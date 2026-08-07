import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';

void main() {
  test('manual cover can be uncollected while auto cover stays protected', () {
    final manualCover = ImageFavorite(
      1,
      'cover.jpg',
      null,
      'chapter-1',
      'comic-1',
      1,
      'source',
      'Chapter 1',
    );
    final autoCover = manualCover.copyWith(isAutoFavorite: true);

    expect(canUncollectImageFavorite(manualCover), isTrue);
    expect(canUncollectImageFavorite(autoCover), isFalse);
    expect(canUncollectImageFavorite(null), isFalse);
  });
}
