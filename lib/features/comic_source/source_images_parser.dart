import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/image_loading_config.dart';

import 'normalization.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceImagesParser {
  const SourceImagesParser(this.context);
  final SourceParserContext context;

  LoadComicPagesFunc? parseLoadComicPagesFunc() {
    return (id, ep) async {
      try {
        final images = await JsEngine().runReadCodeToCompletion<List<String>>(
          """
          ComicSource.sources.${context.key}.comic.loadEp(${jsonEncode(id)}, ${jsonEncode(ep)})
        """,
          consume: (raw) {
            final result = normalizeComicSourceStringListResult(raw, 'images');
            if (result == null) throw 'Invalid data';
            return List<String>.of(result.items);
          },
        );
        return Res(images);
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
      return _resolveLoadingConfig("""
          ComicSource.sources.${context.key}.comic.onImageLoad(
            ${jsonEncode(imageKey)}, ${jsonEncode(comicId)}, ${jsonEncode(ep)})
        """, 'onImageLoad');
    };
  }

  GetThumbnailLoadingConfigFunc? parseThumbnailLoadingConfigFunc() {
    if (!context.checkExists("comic.onThumbnailLoad")) {
      return null;
    }
    return (imageKey) {
      return _resolveLoadingConfig("""
          ComicSource.sources.${context.key}.comic.onThumbnailLoad(${jsonEncode(imageKey)})
        """, 'onThumbnailLoad');
    };
  }

  FutureOr<Map<String, dynamic>> _resolveLoadingConfig(
    String code,
    String hook,
  ) {
    final engine = JsEngine();
    final Object? result;
    try {
      result = engine.runOwnedCode(code);
    } catch (error, stack) {
      _throwInvocationFailure(error, stack);
    }
    if (result is Future) {
      return result.then<Map<String, dynamic>>(
        (value) => _normalizeLoadingConfig(value, hook),
        onError: _throwInvocationFailure,
      );
    }
    return _normalizeLoadingConfig(result, hook);
  }

  Never _throwInvocationFailure(Object error, StackTrace stack) {
    // JS can throw/reject a container containing native functions. Preserve
    // the original diagnostic object, but release references no caller owns.
    try {
      discardImageLoadingConfig(error);
    } on ImageLoadingConfigCleanupFailure catch (cleanup) {
      throw ImageLoadingConfigFailure(
        cause: error,
        stackTrace: stack,
        cleanupFailure: cleanup,
      );
    }
    Error.throwWithStackTrace(error, stack);
  }

  Map<String, dynamic> _normalizeLoadingConfig(Object? raw, String hook) {
    try {
      final config = normalizeComicSourceLoadingConfig(raw);
      if (config == null) {
        final message = 'function $hook return invalid data';
        Log.error('Network', message);
        throw message;
      }
      return config;
    } catch (error, stack) {
      // The caller only owns a successfully normalized configuration. Failed
      // results can still contain native callback references at any depth.
      try {
        discardImageLoadingConfig(raw);
      } on ImageLoadingConfigCleanupFailure catch (cleanup) {
        throw ImageLoadingConfigFailure(
          cause: error,
          stackTrace: stack,
          cleanupFailure: cleanup,
        );
      }
      rethrow;
    }
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
