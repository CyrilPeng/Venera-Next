import 'dart:async';
import 'dart:convert';

import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'models.dart';
import 'source.dart';

import 'source_parser_context.dart';
import 'source_parse_exception.dart';

class SourceExploreParser {
  const SourceExploreParser(this.context);
  final SourceParserContext context;

  List<ExplorePageData> loadExploreData() {
    if (!context.checkExists("explore")) {
      return const [];
    }
    var length = context.runCode("${context.sourceExpression}.explore.length");
    var pages = <ExplorePageData>[];
    for (int i = 0; i < length; i++) {
      final String title = context.getValue("explore[$i].title");
      final String type = context.getValue("explore[$i].type");
      Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;
      Future<Res<List<Comic>>> Function(int page)? loadPage;
      Future<Res<List<Comic>>> Function(String? next)? loadNext;
      Future<Res<List<Object>>> Function(int index)? loadMixed;
      if (type == "singlePageWithMultiPart") {
        loadMultiPart = () async {
          try {
            var res = await context.runReadCode(
              "${context.sourceExpression}.explore[$i].load()",
            );
            return Res(
              List.from(
                res.keys
                    .map(
                      (e) => ExplorePagePart(
                        e,
                        (res[e] as List)
                            .map<Comic>((e) => Comic.fromJson(e, context.key))
                            .toList(),
                        null,
                      ),
                    )
                    .toList(),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.fromException(e, s);
          }
        };
      } else if (type == "multiPageComicList") {
        if (context.checkExists("explore[$i].load")) {
          loadPage = (int page) async {
            try {
              var res = await context.runReadCode(
                "${context.sourceExpression}.explore[$i].load(${jsonEncode(page)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], context.key),
                ),
                subData: res["maxPage"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.fromException(e, s);
            }
          };
        } else {
          loadNext = (next) async {
            try {
              var res = await context.runReadCode(
                "${context.sourceExpression}.explore[$i].loadNext(${jsonEncode(next)})",
              );
              return Res(
                List.generate(
                  res["comics"].length,
                  (index) => Comic.fromJson(res["comics"][index], context.key),
                ),
                subData: res["next"],
              );
            } catch (e, s) {
              Log.error("Network", "$e\n$s");
              return Res.fromException(e, s);
            }
          };
        }
      } else if (type == "multiPartPage") {
        loadMultiPart = () async {
          try {
            var res = await context.runReadCode(
              "${context.sourceExpression}.explore[$i].load()",
            );
            return Res(
              List.from(
                (res as List).map((e) {
                  return ExplorePagePart(
                    e['title'],
                    (e['comics'] as List).map((e) {
                      return Comic.fromJson(e, context.key);
                    }).toList(),
                    PageJumpTarget.parse(context.key, e['viewMore']),
                  );
                }),
              ),
            );
          } catch (e, s) {
            Log.error("Data Analysis", "$e\n$s");
            return Res.fromException(e, s);
          }
        };
      } else if (type == 'mixed') {
        loadMixed = (index) async {
          try {
            var res = await context.runReadCode(
              "${context.sourceExpression}.explore[$i].load(${jsonEncode(index)})",
            );
            var list = <Object>[];
            for (var data in (res['data'] as List)) {
              if (data is List) {
                list.add(
                  data.map((e) => Comic.fromJson(e, context.key)).toList(),
                );
              } else if (data is Map) {
                list.add(
                  ExplorePagePart(
                    data['title'],
                    (data['comics'] as List).map((e) {
                      return Comic.fromJson(e, context.key);
                    }).toList(),
                    data['viewMore'],
                  ),
                );
              }
            }
            return Res(list, subData: res['maxPage']);
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return Res.fromException(e, s);
          }
        };
      }
      pages.add(
        ExplorePageData(
          title,
          switch (type) {
            "singlePageWithMultiPart" =>
              ExplorePageType.singlePageWithMultiPart,
            "multiPartPage" => ExplorePageType.singlePageWithMultiPart,
            "multiPageComicList" => ExplorePageType.multiPageComicList,
            "mixed" => ExplorePageType.mixed,
            _ => throw ComicSourceParseException(
              "Unknown explore page type $type",
            ),
          },
          loadPage,
          loadNext,
          loadMultiPart,
          loadMixed,
        ),
      );
    }
    return pages;
  }
}
