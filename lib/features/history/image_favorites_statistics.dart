import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'image_favorites_models.dart';
import 'image_favorites_repository.dart';

/// Uses a read-only, operation-owned connection without application bootstrap.
Future<ImageFavoritesComputed> readImageFavoritesStatistics(String path) =>
    Isolate.run(() {
      final database = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        return computeImageFavorites(
          ImageFavoritesRepository(database).getAll(),
        );
      } finally {
        database.dispose();
      }
    });

ImageFavoritesComputed computeImageFavorites(List<ImageFavoritesComic> comics) {
  const maxLength = 20;

  // 去掉这些没有意义的标签
  const List<String> exceptTags = [
    '連載中',
    '',
    'translated',
    'chinese',
    'sole male',
    'sole female',
    'original',
    'doujinshi',
    'manga',
    'multi-work series',
    'mosaic censorship',
    'dilf',
    'bbm',
    'uncensored',
    'full censorship',
  ];

  Map<String, int> tagCount = {};
  Map<String, int> authorCount = {};
  Map<ImageFavoritesComic, int> comicImageCount = {};
  int count = 0;

  for (var comic in comics) {
    count += comic.images.length;
    for (var tag in comic.tags) {
      String finalTag = tag.split(":").last;
      tagCount[finalTag] = (tagCount[finalTag] ?? 0) + 1;
    }

    if (comic.author != "") {
      String finalAuthor = comic.author;
      authorCount[finalAuthor] =
          (authorCount[finalAuthor] ?? 0) + comic.images.length;
    }
    // 小于10页的漫画不统计
    if (comic.maxPageFromEp < 10) {
      continue;
    }
    comicImageCount[comic] =
        (comicImageCount[comic] ?? 0) + comic.images.length;
  }

  // 按数量排序标签
  List<String> sortedTags = tagCount.keys.toList()
    ..sort((a, b) => tagCount[b]!.compareTo(tagCount[a]!));

  // 按数量排序作者
  List<String> sortedAuthors = authorCount.keys.toList()
    ..sort((a, b) => authorCount[b]!.compareTo(authorCount[a]!));

  // 按收藏数量排序漫画
  List<MapEntry<ImageFavoritesComic, int>> sortedComicsByNum =
      comicImageCount.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

  validateTag(String tag) {
    if (tag.startsWith("Category:")) {
      return false;
    }
    return !exceptTags.contains(tag.split(":").last.toLowerCase()) &&
        !tag.isNum;
  }

  return ImageFavoritesComputed(
    sortedTags
        .where(validateTag)
        .map((tag) => TextWithCount(tag, tagCount[tag]!))
        .take(maxLength)
        .toList(),
    sortedAuthors
        .map((author) => TextWithCount(author, authorCount[author]!))
        .take(maxLength)
        .toList(),
    sortedComicsByNum
        .map((comic) => TextWithCount(comic.key.title, comic.value))
        .take(maxLength)
        .toList(),
    count,
  );
}
