import 'image_favorites_repository.dart';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'package:venera_next/features/history/image_favorites_provider.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/log.dart';

class ImageFavoriteManager with ChangeNotifier {
  ImageFavoritesRepository get _repository =>
      ImageFavoritesRepository(HistoryManager().imageFavoritesDatabase);

  List<ImageFavoritesComic> get comics => getAll();

  static ImageFavoriteManager? _cache;

  ImageFavoriteManager._();

  factory ImageFavoriteManager() => (_cache ??= ImageFavoriteManager._());

  void init() => _repository.initialize();

  void addOrUpdateOrDelete(ImageFavoritesComic favorite, [bool notify = true]) {
    _repository.save(favorite);
    if (notify) notifyListeners();
  }

  List<ImageFavoritesComic> getAll([String? keyword]) {
    try {
      return _repository.getAll(keyword);
    } on SqliteException {
      rethrow;
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
      return [];
    }
  }

  void deleteImageFavorite(Iterable<ImageFavorite> imageFavoriteList) {
    final images = imageFavoriteList.toList();
    if (images.isEmpty) {
      return;
    }
    var comics = <ImageFavoritesComic>{};
    for (var i in images) {
      var comic =
          comics
              .where((c) => c.id == i.id && c.sourceKey == i.sourceKey)
              .firstOrNull ??
          find(i.id, i.sourceKey);
      if (comic == null) {
        continue;
      }
      var ep = comic.imageFavoritesEp.firstWhereOrNull((e) => e.ep == i.ep);
      if (ep == null) {
        continue;
      }
      ep.imageFavorites.remove(i);
      if (ep.imageFavorites.isEmpty) {
        comic.imageFavoritesEp.remove(ep);
      }
      comics.add(comic);
    }
    _repository.saveAll(comics);
    for (final image in images) {
      ImageFavoritesProvider.deleteFromCache(image).catchError((
        Object error,
        StackTrace stack,
      ) {
        Log.error('Image Favorites', error, stack);
      });
    }
    notifyListeners();
  }

  int get length => _repository.count();

  void notifyChanges() {
    notifyListeners();
  }

  List<ImageFavoritesComic> search(String keyword) {
    if (keyword == "") {
      return [];
    }
    return getAll(keyword);
  }

  static Future<ImageFavoritesComputed> computeImageFavorites() {
    var token = ServicesBinding.rootIsolateToken!;
    var count = ImageFavoriteManager().length;
    if (count == 0) {
      return Future.value(ImageFavoritesComputed([], [], [], 0));
    } else if (count > 100) {
      return Isolate.run(() async {
        BackgroundIsolateBinaryMessenger.ensureInitialized(token);
        await App.init();
        await HistoryManager().init();
        return _computeImageFavorites();
      });
    } else {
      return Future.value(_computeImageFavorites());
    }
  }

  static ImageFavoritesComputed _computeImageFavorites() {
    const maxLength = 20;

    var comics = ImageFavoriteManager().getAll();
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
    Map<ImageFavoritesComic, int> comicMaxPages = {};
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
      comicMaxPages[comic] = (comicMaxPages[comic] ?? 0) + comic.maxPageFromEp;
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

  ImageFavoritesComic? find(String id, String sourceKey) =>
      _repository.find(id, sourceKey);
}
