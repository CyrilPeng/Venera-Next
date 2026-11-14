import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorite_actions.dart';

ImageFavoritesComic comic(
  String id, {
  String source = 'source',
}) => ImageFavoritesComic(
  id,
  [
    ImageFavoritesEp(
      'chapter',
      1,
      [ImageFavorite(1, 'image', null, 'chapter', id, 1, source, 'Chapter')],
      'Chapter',
      12,
    ),
  ],
  'Title $id',
  source,
  ['Tag', '', 'more'],
  ['translated'],
  DateTime.fromMillisecondsSinceEpoch(1234),
  'Author',
  {'custom': 3},
  'Subtitle',
  12,
);

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
