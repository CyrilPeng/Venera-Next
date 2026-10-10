import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'image_favorites_models.dart';
import 'image_favorites_row.dart';

/// Image favorite storage on a caller-owned connection, without cache or UI.
class ImageFavoritesRepository {
  ImageFavoritesRepository(this.db, {String schema = 'main'})
    : _table = '"${schema.replaceAll('"', '""')}"."image_favorites"';
  final Database db;
  final String _table;

  /// 检查表image_favorites是否存在, 不存在则创建
  void initialize() {
    db.execute(
      "CREATE TABLE IF NOT EXISTS $_table ("
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
  void save(ImageFavoritesComic favorite) {
    // 没有章节了就删掉
    if (favorite.imageFavoritesEp.isEmpty) {
      db.execute(
        """
      delete from $_table
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
        throw OperationFailure.message("Error: No ImageFavoritesEp");
      }
      db.execute(
        """
      insert or replace into $_table(id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
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
  }

  List<ImageFavoritesComic> getAll([String? keyword]) {
    ResultSet res;
    if (keyword == null || keyword == "") {
      res = db.select("select * from $_table;");
    } else {
      res = db.select(
        """
    select * from $_table
    WHERE title LIKE ?
    OR sub_title LIKE ?
    OR LOWER(tags) LIKE LOWER(?)
    OR LOWER(translated_tags) LIKE LOWER(?)
    OR author LIKE ?;
    """,
        ['%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%'],
      );
    }
    return res.map(imageFavoritesComicFromRow).toList();
  }

  ImageFavoritesComic? find(String id, String sourceKey) {
    var row = db.select(
      """
    select * from $_table
    where id == ? and source_key == ?;
    """,
      [id, sourceKey],
    );
    if (row.isEmpty) {
      return null;
    }
    return imageFavoritesComicFromRow(row.first);
  }

  int count() =>
      db.select('SELECT count(*) AS total FROM $_table;').first['total'] as int;

  /// Re-read under the caller's admission and commit all selected removals in
  /// one transaction. Source/chapter/page identity retains legacy semantics.
  void removeImages(Iterable<ImageFavorite> images) =>
      runSqliteTransaction(db, () {
        final comics = <ImageFavoritesComic>{};
        for (final image in images) {
          final comic =
              comics
                  .where(
                    (comic) =>
                        comic.id == image.id &&
                        comic.sourceKey == image.sourceKey,
                  )
                  .firstOrNull ??
              find(image.id, image.sourceKey);
          if (comic == null) continue;
          final chapter = comic.imageFavoritesEp
              .where((ep) => ep.ep == image.ep)
              .firstOrNull;
          if (chapter == null) continue;
          chapter.imageFavorites.remove(image);
          if (chapter.imageFavorites.isEmpty) {
            comic.imageFavoritesEp.remove(chapter);
          }
          comics.add(comic);
        }
        for (final comic in comics) {
          save(comic);
        }
      }, immediate: true);

  void saveAll(Iterable<ImageFavoritesComic> comics) =>
      runSqliteTransaction(db, () {
        for (final comic in comics) {
          save(comic);
        }
      }, immediate: true);
}
