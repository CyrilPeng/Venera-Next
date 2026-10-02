import 'package:flutter_qjs/flutter_qjs.dart';
import 'dart:convert';

import 'package:venera_next/foundation/js_engine.dart';

import 'models.dart';
import 'normalization.dart';
import 'source.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceMetadataParser {
  const SourceMetadataParser(this.context);
  final SourceParserContext context;

  Map<String, Map<String, dynamic>> parseSettings() {
    final value = context.getValue("settings");
    try {
      return normalizeComicSourceSettings(
            value,
            retainCallback: context.callbacks.retain,
          ) ??
          {};
    } finally {
      JSRef.freeRecursive(value);
    }
  }

  RegExp? parseIdMatch() {
    if (!context.checkExists("comic.idMatch")) {
      return null;
    }
    return RegExp(context.getValue("comic.idMatch"));
  }

  Map<String, Map<String, String>>? parseTranslation() {
    if (!context.checkExists("translation")) {
      return null;
    }
    var data = context.getValue("translation");
    var res = <String, Map<String, String>>{};
    for (var e in data.entries) {
      res[e.key] = Map<String, String>.from(e.value);
    }
    return res;
  }

  HandleClickTagEvent? parseClickTagEvent() {
    if (!context.checkExists("comic.onClickTag")) {
      return null;
    }
    return (namespace, tag) {
      var res = JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.onClickTag(${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      if (res is! Map) {
        return null;
      }
      var r = Map<String, dynamic>.from(res);
      r.removeWhere((key, value) => value == null);
      return PageJumpTarget.parse(context.key, r);
    };
  }

  LinkHandler? parseLinkHandler() {
    if (!context.checkExists("comic.link")) {
      return null;
    }
    List<String> domains = List.from(context.getValue("comic.link.domains"));
    linkToId(String link) {
      var res = JsEngine().runCode("""
          ComicSource.sources.${context.key}.comic.link.linkToId(${jsonEncode(link)})
        """);
      return res as String?;
    }

    return LinkHandler(domains, linkToId);
  }
}
