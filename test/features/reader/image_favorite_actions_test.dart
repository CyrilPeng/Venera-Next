import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorite_actions.dart';

ImageFavoriteInput selection({int page = 2, String eid = 'chapter'}) =>
    ImageFavoriteInput(
      id: 'comic',
      sourceKey: 'source',
      eid: eid,
      ep: 1,
      epName: 'Chapter',
      title: 'Title',
      subtitle: 'Subtitle',
      author: 'Author',
      tags: ['tag'],
      translatedTags: ['translated'],
      maxPage: 10,
      page: page,
      imageKey: 'image-$page',
      coverKey: 'image-1',
    );

void main() {
  late ImageFavoriteActions service;
  ImageFavoritesComic? stored;
  var saves = 0;
  final removed = <ImageFavorite>[];
  setUp(() {
    stored = null;
    saves = 0;
    removed.clear();
    service = ImageFavoriteActions(
      findComic: (id, source) =>
          stored?.id == id && stored?.sourceKey == source ? stored : null,
      save: (comic) {
        stored = comic;
        saves++;
      },
      remove: (image) {
        removed.add(image);
        stored!.imageFavoritesEp.single.imageFavorites.remove(image);
      },
      now: () => DateTime(2026, 10, 1),
    );
  });

  test(
    'collecting a later image adds a protected cover and preserves metadata',
    () {
      expect(service.toggle(selection()), ImageFavoriteResult.collected);
      final comic = stored!;
      expect(comic.title, 'Title');
      expect(comic.subTitle, 'Subtitle');
      expect(comic.translatedTags, ['translated']);
      expect(comic.time, DateTime(2026, 10, 1));
      expect(comic.maxPage, 10);
      final chapter = comic.imageFavoritesEp.single;
      expect(chapter.imageFavorites.map((image) => image.page), [1, 2]);
      expect(chapter.imageFavorites.first.imageKey, 'image-1');
      expect(
        service.toggle(selection(page: 1)),
        ImageFavoriteResult.protectedCover,
      );
      expect(saves, 1);
      expect(removed, isEmpty);
      expect(service.toggle(selection()), ImageFavoriteResult.uncollected);
      expect(removed.single.page, 2);
      expect(service.find('comic', 'source', 'chapter', 2), isNull);
      expect(service.find('comic', 'other', 'chapter', 1), isNull);
    },
  );

  test('an explicitly collected first image can be removed', () {
    service.toggle(selection(page: 1));
    expect(stored!.imageFavoritesEp.single.imageFavorites, hasLength(1));
    expect(service.toggle(selection(page: 1)), ImageFavoriteResult.uncollected);
    expect(removed.single.isAutoFavorite, isNull);
  });

  test('chapter reordering is refused without saving or mutating images', () {
    service.toggle(selection());
    expect(
      service.toggle(selection(page: 3, eid: 'changed')),
      ImageFavoriteResult.chapterOrderChanged,
    );
    expect(saves, 1);
    expect(
      stored!.imageFavoritesEp.single.imageFavorites.map((image) => image.page),
      [1, 2],
    );
    expect(stored!.imageFavoritesEp.single.eid, 'chapter');
  });

  test(
    'storage failures propagate to the UI adapter and later attempts can recover',
    () {
      var fail = true;
      final isolated = ImageFavoriteActions(
        findComic: (_, _) => null,
        save: (comic) {
          if (fail) throw StateError('storage');
          stored = comic;
        },
        remove: (_) {},
      );
      expect(() => isolated.toggle(selection()), throwsStateError);
      fail = false;
      expect(isolated.toggle(selection()), ImageFavoriteResult.collected);
      expect(stored!.imageFavoritesEp.single.imageFavorites, hasLength(2));
    },
  );
}
