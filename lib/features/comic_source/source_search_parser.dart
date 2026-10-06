import 'dart:collection';
import 'dart:convert';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'source.dart';
import 'types.dart';

import 'source_parser_context.dart';

class SourceSearchParser {
  const SourceSearchParser(this.context);
  final SourceParserContext context;

  SearchPageData? loadSearchData() {
    if (!context.checkExists("search")) return null;
    var options = <SearchOptions>[];
    for (var element in context.getValue("search.optionList") ?? []) {
      LinkedHashMap<String, String> map = LinkedHashMap<String, String>();
      for (var option in element["options"]) {
        if (option.isEmpty || !option.contains("-")) {
          continue;
        }
        var split = option.split("-");
        var key = split.removeAt(0);
        var value = split.join("-");
        map[key] = value;
      }
      options.add(
        SearchOptions(
          map,
          element["label"],
          element['type'] ?? 'select',
          element['default'] == null ? null : jsonEncode(element['default']),
        ),
      );
    }

    SearchFunction? loadPage;

    SearchNextFunction? loadNext;

    if (context.checkExists('search.load')) {
      loadPage = (keyword, page, searchOption) async {
        try {
          var res = await context.runReadCode("""
          ${context.sourceExpression}.search.load(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(page)})
        """);
          return context.parseComicListResult(res, "maxPage");
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.fromException(e, s);
        }
      };
    } else {
      loadNext = (keyword, next, searchOption) async {
        try {
          var res = await context.runReadCode("""
          ${context.sourceExpression}.search.loadNext(
            ${jsonEncode(keyword)}, ${jsonEncode(searchOption)}, ${jsonEncode(next)})
        """);
          return context.parseComicListResult(res, "next");
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return Res.fromException(e, s);
        }
      };
    }

    return SearchPageData(options, loadPage, loadNext);
  }

  TagSuggestionSelectFunc? parseTagSuggestionSelectFunc() {
    if (!context.checkExists("search.onTagSuggestionSelected")) {
      return null;
    }
    return (namespace, tag) {
      var res = context.runCode("""
          ${context.sourceExpression}.search.onTagSuggestionSelected(
            ${jsonEncode(namespace)}, ${jsonEncode(tag)})
        """);
      return res is String ? res : "$namespace:$tag";
    };
  }
}
