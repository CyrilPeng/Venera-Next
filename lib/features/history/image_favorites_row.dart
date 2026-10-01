import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'image_favorites_models.dart';

ImageFavoritesComic imageFavoritesComicFromRow(Row r) {
  var tempImageFavoritesEp = jsonDecode(r["image_favorites_ep"]);
  List<ImageFavoritesEp> finalImageFavoritesEp = [];
  tempImageFavoritesEp.forEach((i) {
    List<ImageFavorite> temp = [];
    i["imageFavorites"].forEach((j) {
      temp.add(
        ImageFavorite(
          j["page"],
          j["imageKey"],
          j["isAutoFavorite"],
          i["eid"],
          r["id"],
          i["ep"],
          r["source_key"],
          i["epName"],
        ),
      );
    });
    finalImageFavoritesEp.add(
      ImageFavoritesEp(i["eid"], i["ep"], temp, i["epName"], i["maxPage"] ?? 1),
    );
  });
  return ImageFavoritesComic(
    r["id"],
    finalImageFavoritesEp,
    r["title"],
    r["source_key"],
    r["tags"].split(","),
    r["translated_tags"].split(","),
    DateTime.fromMillisecondsSinceEpoch(r["time"]),
    r["author"],
    jsonDecode(r["other"]),
    r["sub_title"],
    r["max_page"],
  );
}
