import 'dart:convert';

import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'models.dart';
import 'normalization.dart';
import 'source.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceComicParser {
  const SourceComicParser(this.context);
  final SourceParserContext context;

  LoadComicFunc? parseLoadComicFunc() {
    return (id) async {
      try {
        var res = await JsEngine().runReadCode("""
          ComicSource.sources.${context.key}.comic.loadInfo(${jsonEncode(id)})
        """);
        res = normalizeComicSourceComicDetails(res, context.key, id);
        if (res == null) throw "Invalid data";
        return Res(ComicDetails.fromJson(res));
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  LikeOrUnlikeComicFunc? parseLikeFunc() {
    if (!context.checkExists("comic.likeComic")) {
      return null;
    }
    return (id, isLiking) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.likeComic(${jsonEncode(id)}, ${jsonEncode(isLiking)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  StarRatingFunc? parseStarRatingFunc() {
    if (!context.checkExists("comic.starRating")) {
      return null;
    }
    return (id, rating) async {
      try {
        await JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.starRating(${jsonEncode(id)}, ${jsonEncode(rating)})
        """);
        return const Res(true);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.error(e.toString());
      }
    };
  }

  ArchiveDownloader? parseArchiveDownloader() {
    if (!context.checkExists("comic.archive")) {
      return null;
    }
    return ArchiveDownloader(
      (cid) async {
        try {
          var res = await JsEngine().runReadCode("""
              ComicSource.sources.${context.key}.comic.archive.getArchives(${jsonEncode(cid)})
            """);
          final archives = normalizeComicSourceArchiveList(res);
          if (archives == null) throw "Invalid data";
          return Res(archives);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
      (cid, aid) async {
        try {
          var res = await JsEngine().runReadCode("""
              ComicSource.sources.${context.key}.comic.archive.getDownloadUrl(${jsonEncode(cid)}, ${jsonEncode(aid)})
            """);
          final url = normalizeComicSourceArchiveDownloadUrl(res);
          if (url == null) throw "Invalid data";
          return Res(url);
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.error(e.toString());
        }
      },
    );
  }
}
