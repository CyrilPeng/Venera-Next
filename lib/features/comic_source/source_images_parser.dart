import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'normalization.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceImagesParser {
  const SourceImagesParser(this.context);
  final SourceParserContext context;

  LoadComicPagesFunc? parseLoadComicPagesFunc() {
    return (id, ep) async {
      try {
        var res = await JsEngine().runReadCode("""
          ComicSource.sources.${context.key}.comic.loadEp(${jsonEncode(id)}, ${jsonEncode(ep)})
        """);
        final result = normalizeComicSourceStringListResult(res, "images");
        if (result == null) throw "Invalid data";
        return Res(result.items);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.fromException(e, s);
      }
    };
  }

  GetImageLoadingConfigFunc? parseImageLoadingConfigFunc() {
    if (!context.checkExists("comic.onImageLoad")) {
      return null;
    }
    return (imageKey, comicId, ep) async {
      var res = JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.onImageLoad(
            ${jsonEncode(imageKey)}, ${jsonEncode(comicId)}, ${jsonEncode(ep)})
        """);
      if (res is Future) {
        res = await res;
      }
      final config = normalizeComicSourceLoadingConfig(res);
      if (config == null) {
        Log.error("Network", "function onImageLoad return invalid data");
        throw "function onImageLoad return invalid data";
      }
      return config;
    };
  }

  GetThumbnailLoadingConfigFunc? parseThumbnailLoadingConfigFunc() {
    if (!context.checkExists("comic.onThumbnailLoad")) {
      return null;
    }
    return (imageKey) {
      var res = JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.onThumbnailLoad(${jsonEncode(imageKey)})
        """);
      final config = normalizeComicSourceLoadingConfig(res);
      if (config == null) {
        Log.error("Network", "function onThumbnailLoad return invalid data");
        throw "function onThumbnailLoad return invalid data";
      }
      return config;
    };
  }

  ComicThumbnailLoader? parseThumbnailLoader() {
    if (!context.checkExists("comic.loadThumbnails")) {
      return null;
    }
    return (id, next) async {
      try {
        var res = await JsEngine().runReadCode("""
          ComicSource.sources.${context.key}.comic.loadThumbnails(${jsonEncode(id)}, ${jsonEncode(next)})
        """);
        final result = normalizeComicSourceStringListResult(res, 'thumbnails');
        if (result == null) throw "Invalid data";
        return Res(result.items, subData: result.data['next']);
      } catch (e, s) {
        Log.error("Network", "$e\n$s");
        return Res.fromException(e, s);
      }
    };
  }
}
