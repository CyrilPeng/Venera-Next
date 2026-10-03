import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/translations.dart';

import 'comic_type_bridge.dart';
import 'js_bridge.dart';
import 'source.dart';
import 'source_parser_context.dart';
import 'source_parse_exception.dart';
import 'source_metadata_parser.dart';
import 'source_comic_parser.dart';
import 'source_images_parser.dart';
import 'source_comments_parser.dart';
import 'source_favorites_parser.dart';
import 'source_search_parser.dart';
import 'source_category_parser.dart';
import 'source_explore_parser.dart';
import 'source_account_parser.dart';

export 'source_parse_exception.dart';

/// return true if ver1 > ver2
bool compareSemVer(String ver1, String ver2) {
  ver1 = ver1.replaceFirst("-", ".");
  ver2 = ver2.replaceFirst("-", ".");
  List<String> v1 = ver1.split('.');
  List<String> v2 = ver2.split('.');

  for (int i = 0; i < 3; i++) {
    int num1 = int.parse(v1[i]);
    int num2 = int.parse(v2[i]);

    if (num1 > num2) {
      return true;
    } else if (num1 < num2) {
      return false;
    }
  }

  var v14 = v1.elementAtOrNull(3);
  var v24 = v2.elementAtOrNull(3);

  if (v14 != v24) {
    if (v14 == null && v24 != "hotfix") {
      return true;
    } else if (v14 == null) {
      return false;
    }
    if (v24 == null) {
      if (v14 == "hotfix") {
        return true;
      }
      return false;
    }
    return v14.compareTo(v24) > 0;
  }

  return false;
}

String sourceClassName(String script) {
  final match = RegExp(
    r'^\s*class\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s+extends\s+ComicSource\b',
    multiLine: true,
  ).firstMatch(script.replaceFirst('\uFEFF', ''));
  if (match == null) {
    throw ComicSourceParseException(
      'Expected a class declaration extending ComicSource.',
    );
  }
  return match.group(1)!;
}

class ComicSourceParser {
  JSInvokable? _restore;
  JsCallbackScope? _callbacks;

  /// Restore the previous runtime object if a later disk commit fails.
  void rollback() {
    try {
      _restore?.invoke([]);
    } finally {
      _callbacks?.dispose();
      commit();
    }
  }

  void commit() {
    _restore?.free();
    _restore = null;
    _callbacks = null;
  }

  /// comic source key
  String? _key;

  String? _name;

  Future<ComicSource> createAndParse(
    String js,
    String fileName, {
    String? expectedKey,
    bool retainRollback = false,
  }) async {
    if (!fileName.endsWith(".js")) {
      fileName = "$fileName.js";
    }
    var file = File(FilePath.join(App.dataPath, "comic_source", fileName));
    if (file.existsSync()) {
      int i = 0;
      while (file.existsSync()) {
        file = File(
          FilePath.join(
            App.dataPath,
            "comic_source",
            "${fileName.split('.').first}($i).js",
          ),
        );
        i++;
      }
    }
    try {
      await file.writeAsString(js);
      return await parse(
        js,
        file.path,
        expectedKey: expectedKey,
        retainRollback: retainRollback,
      );
    } catch (e) {
      await file.deleteIfExists();
      rethrow;
    }
  }

  Future<ComicSource> parse(
    String js,
    String filePath, {
    String? expectedKey,
    bool replacing = false,
    bool retainRollback = false,
  }) async {
    try {
      final source = await _parse(
        js,
        filePath,
        expectedKey: expectedKey,
        replacing: replacing,
      );
      if (!retainRollback) commit();
      return source;
    } catch (_) {
      rollback();
      rethrow;
    } finally {
      JsEngine().runCode("delete this['temp'];");
    }
  }

  Future<ComicSource> _parse(
    String js,
    String filePath, {
    String? expectedKey,
    bool replacing = false,
  }) async {
    configureComicTypeSourceKeyResolver();
    configureComicSourceJsDataBridge();
    js = js.replaceAll("\r\n", "\n");
    final className = sourceClassName(js);
    JsEngine().runCode("""(() => { $js
        this['temp'] = new $className()
      }).call()
    """, filePath);
    _name =
        JsEngine().runCode("this['temp'].name") ??
        (throw ComicSourceParseException('name is required'));
    var key =
        JsEngine().runCode("this['temp'].key") ??
        (throw ComicSourceParseException('key is required'));
    var version =
        JsEngine().runCode("this['temp'].version") ??
        (throw ComicSourceParseException('version is required'));
    var minAppVersion = JsEngine().runCode("this['temp'].minAppVersion");
    var url = JsEngine().runCode("this['temp'].url");
    if (expectedKey != null && key != expectedKey) {
      throw ComicSourceParseException(
        'The downloaded script does not match this source.'.tl,
      );
    }
    if (minAppVersion != null) {
      if (compareSemVer(minAppVersion, App.version.split('-').first)) {
        throw ComicSourceParseException(
          "minAppVersion @version is required".tlParams({
            "version": minAppVersion,
          }),
        );
      }
    }
    for (var source in ComicSource.all()) {
      if (source.key == key && !(replacing && expectedKey == key)) {
        throw SourceAlreadyInstalledException(key);
      }
    }
    _key = key;
    _checkKeyValidation();

    _restore =
        JsEngine().runCode('''(() => {
      const previous = ComicSource.sources[${jsonEncode(key)}];
      return () => {
        if (previous === undefined) delete ComicSource.sources[${jsonEncode(key)}];
        else ComicSource.sources[${jsonEncode(key)}] = previous;
      };
    })()''')
            as JSInvokable;

    JsEngine().runCode("""
      void (ComicSource.sources.$_key = this['temp']);
    """);

    final callbacks = _callbacks = JsCallbackScope();
    final context = SourceParserContext(
      key: key,
      name: _name!,
      callbacks: callbacks,
    );
    final account = SourceAccountParser(context);
    final explore = SourceExploreParser(context);
    final category = SourceCategoryParser(context);
    final search = SourceSearchParser(context);
    final favorites = SourceFavoritesParser(context);
    final comments = SourceCommentsParser(context);
    final images = SourceImagesParser(context);
    final comic = SourceComicParser(context);
    final metadata = SourceMetadataParser(context);

    var source = ComicSource(
      _name!,
      key,
      account.loadAccountConfig(),
      category.loadCategoryData(),
      category.loadCategoryComicsData(),
      favorites.loadFavoriteData(),
      explore.loadExploreData(),
      search.loadSearchData(),
      metadata.parseSettings(),
      comic.parseLoadComicFunc(),
      images.parseThumbnailLoader(),
      images.parseLoadComicPagesFunc(),
      images.parseImageLoadingConfigFunc(),
      images.parseThumbnailLoadingConfigFunc(),
      filePath,
      url ?? "",
      version ?? "1.0.0",
      comments.parseCommentsLoader(),
      comments.parseSendCommentFunc(),
      comments.parseChapterCommentsLoader(),
      comments.parseSendChapterCommentFunc(),
      comic.parseLikeFunc(),
      comments.parseVoteCommentFunc(),
      comments.parseLikeCommentFunc(),
      metadata.parseIdMatch(),
      metadata.parseTranslation(),
      metadata.parseClickTagEvent(),
      search.parseTagSuggestionSelectFunc(),
      metadata.parseLinkHandler(),
      context.getValue("search.enableTagsSuggestions") ?? false,
      context.getValue("comic.enableTagsTranslate") ?? false,
      comic.parseStarRatingFunc(),
      comic.parseArchiveDownloader(),
      runtimeCallbacks: callbacks,
    );

    await source.loadData();

    return source;
  }

  _checkKeyValidation() {
    // 仅允许数字和字母以及下划线
    if (!_key!.contains(RegExp(r"^[a-zA-Z_][a-zA-Z0-9_]*$"))) {
      throw ComicSourceParseException("key $_key is invalid");
    }
  }
}
