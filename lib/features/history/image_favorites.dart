import 'dart:convert';
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
  Database get _db => HistoryManager().imageFavoritesDatabase;

  List<ImageFavoritesComic> get comics => getAll();

  static ImageFavoriteManager? _cache;

  ImageFavoriteManager._();

  factory ImageFavoriteManager() => (_cache ??= ImageFavoriteManager._());

  /// 检查表image_favorites是否存在, 不存在则创建
  void init() {
    _db.execute(
      "CREATE TABLE IF NOT EXISTS image_favorites ("
      "id TEXT,"
      "title TEXT NOT NULL,"
      "sub_title TEXT,"
      "author TEXT,"
      "tags TEXT,"
      "translated_tags TEXT,"
      "time int,"
      "max_page int,"
      "source_key TEXT NOT NULL,"
      "image_favorites_ep TEXT NOT NULL,"
      "other TEXT NOT NULL,"
      "PRIMARY KEY (id,source_key)"
      ");",
    );
  }

  // 做排序和去重的操作
  void addOrUpdateOrDelete(ImageFavoritesComic favorite, [bool notify = true]) {
    // 没有章节了就删掉
    if (favorite.imageFavoritesEp.isEmpty) {
      _db.execute(
        """
      delete from image_favorites
      where id == ? and source_key == ?;
    """,
        [favorite.id, favorite.sourceKey],
      );
    } else {
      // 去重章节
      List<ImageFavoritesEp> tempImageFavoritesEp = [];
      for (var e in favorite.imageFavoritesEp) {
        int index = tempImageFavoritesEp.indexWhere((i) {
          return i.ep == e.ep;
        });
        // 再做一层保险, 防止出现ep为0的脏数据
        if (index == -1 && e.ep > 0) {
          tempImageFavoritesEp.add(e);
        }
      }
      tempImageFavoritesEp.sort((a, b) => a.ep.compareTo(b.ep));
      List<dynamic> finalImageFavoritesEp = jsonDecode(
        jsonEncode(tempImageFavoritesEp),
      );
      for (var e in tempImageFavoritesEp) {
        List<Map> finalImageFavorites = [];
        int epIndex = tempImageFavoritesEp.indexOf(e);
        for (ImageFavorite j in e.imageFavorites) {
          int index = finalImageFavorites.indexWhere(
            (i) => i["page"] == j.page,
          );
          if (index == -1 && j.page > 0) {
            // isAutoFavorite 为 null 不写入数据库, 同时只保留需要的属性, 避免增加太多重复字段在数据库里
            if (j.isAutoFavorite != null) {
              finalImageFavorites.add({
                "page": j.page,
                "imageKey": j.imageKey,
                "isAutoFavorite": j.isAutoFavorite,
              });
            } else {
              finalImageFavorites.add({"page": j.page, "imageKey": j.imageKey});
            }
          }
        }
        finalImageFavorites.sort((a, b) => a["page"].compareTo(b["page"]));
        finalImageFavoritesEp[epIndex]["imageFavorites"] = finalImageFavorites;
      }
      if (tempImageFavoritesEp.isEmpty) {
        throw "Error: No ImageFavoritesEp";
      }
      _db.execute(
        """
      insert or replace into image_favorites(id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
      values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """,
        [
          favorite.id,
          favorite.title,
          favorite.subTitle,
          favorite.author,
          favorite.tags.join(","),
          favorite.translatedTags.join(","),
          favorite.time.millisecondsSinceEpoch,
          favorite.maxPage,
          favorite.sourceKey,
          jsonEncode(finalImageFavoritesEp),
          jsonEncode(favorite.other),
        ],
      );
    }
    if (notify) {
      notifyListeners();
    }
  }

  bool has(String id, String sourceKey, String eid, int page, int ep) {
    var comic = find(id, sourceKey);
    if (comic == null) {
      return false;
    }
    var epIndex = comic.imageFavoritesEp.where((e) => e.eid == eid).firstOrNull;
    if (epIndex == null) {
      return false;
    }
    return epIndex.imageFavorites.any((e) => e.page == page && e.ep == ep);
  }

  List<ImageFavoritesComic> getAll([String? keyword]) {
    ResultSet res;
    if (keyword == null || keyword == "") {
      res = _db.select("select * from image_favorites;");
    } else {
      res = _db.select(
        """
    select * from image_favorites
    WHERE title LIKE ?
    OR sub_title LIKE ?
    OR LOWER(tags) LIKE LOWER(?)
    OR LOWER(translated_tags) LIKE LOWER(?)
    OR author LIKE ?;
    """,
        ['%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%'],
      );
    }
    try {
      return res.map((e) => ImageFavoritesComic.fromRow(e)).toList();
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
      return [];
    }
  }

  void deleteImageFavorite(Iterable<ImageFavorite> imageFavoriteList) {
    if (imageFavoriteList.isEmpty) {
      return;
    }
    for (var i in imageFavoriteList) {
      ImageFavoritesProvider.deleteFromCache(i);
    }
    var comics = <ImageFavoritesComic>{};
    for (var i in imageFavoriteList) {
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
    for (var i in comics) {
      addOrUpdateOrDelete(i, false);
    }
    notifyListeners();
  }

  int get length {
    var res = _db.select("select count(*) from image_favorites;");
    return res.first.values.first! as int;
  }

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

  ImageFavoritesComic? find(String id, String sourceKey) {
    var row = _db.select(
      """
    select * from image_favorites
    where id == ? and source_key == ?;
    """,
      [id, sourceKey],
    );
    if (row.isEmpty) {
      return null;
    }
    return ImageFavoritesComic.fromRow(row.first);
  }
}
