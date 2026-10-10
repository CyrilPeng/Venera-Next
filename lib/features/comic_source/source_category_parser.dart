import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'category.dart';
import 'models.dart';
import 'source.dart';

import 'source_parser_context.dart';

class SourceCategoryParser {
  const SourceCategoryParser(this.context);
  final SourceParserContext context;

  CategoryData? loadCategoryData() {
    final doc = context.getValue("category");
    try {
      if (doc?["title"] == null) {
        return null;
      }

      final String title = doc["title"];
      final bool? enableRankingPage = doc["enableRankingPage"];

      var categoryParts = <BaseCategoryPart>[];

      for (var c in doc["parts"]) {
        if (c["categories"] != null && c["categories"] is! List) {
          continue;
        }
        List? categories = c["categories"];
        if (categories != null && categories.isEmpty) {
          continue;
        }
        if (categories == null || categories[0] is Map) {
          // new format
          final String name = c["name"];
          final String type = c["type"];
          final cs = categories
              ?.map(
                (e) => CategoryItem(
                  e['label'],
                  PageJumpTarget.parse(context.key, e['target']),
                ),
              )
              .toList();
          if (type != "dynamic" && (cs == null || cs.isEmpty)) {
            continue;
          }
          if (type == "fixed") {
            categoryParts.add(FixedCategoryPart(name, cs!));
          } else if (type == "random") {
            categoryParts.add(
              RandomCategoryPart(name, cs!, c["randomNumber"] ?? 1),
            );
          } else if (type == "dynamic" && categories == null) {
            var loader = c["loader"];
            if (loader is! JSInvokable) {
              throw OperationFailure.message(
                "DynamicCategoryPart loader must be a function",
              );
            }
            final invoke = context.retainCallback(loader);
            categoryParts.add(
              DynamicCategoryPart(
                name,
                () => context.consumeSynchronous(() => invoke([]), (data) {
                  if (data is! List) {
                    throw OperationFailure.message(
                      'DynamicCategoryPart loader must return a List',
                    );
                  }
                  return data.map((item) {
                    if (item is! Map) {
                      throw OperationFailure.message(
                        'DynamicCategoryPart loader must return a List of Map',
                      );
                    }
                    final label = item['label'];
                    if (label is! String) {
                      throw OperationFailure.message(
                        'Category label must be a String',
                      );
                    }
                    return CategoryItem(
                      label,
                      PageJumpTarget.parse(context.key, item['target']),
                    );
                  }).toList();
                }),
              ),
            );
          }
        } else {
          // old format
          final String name = c["name"];
          final String type = c["type"];
          final List<String> tags = List.from(c["categories"]);
          final String itemType = c["itemType"];
          List<String>? categoryParams = ListOrNull.from(c["categoryParams"]);
          final String? groupParam = c["groupParam"];
          if (groupParam != null) {
            categoryParams = List.filled(tags.length, groupParam);
          }
          var cs = <CategoryItem>[];
          for (int i = 0; i < tags.length; i++) {
            PageJumpTarget target;
            if (itemType == 'category') {
              target = PageJumpTarget(context.key, 'category', {
                "category": tags[i],
                "param": categoryParams?.elementAtOrNull(i),
              });
            } else if (itemType == 'search') {
              target = PageJumpTarget(context.key, 'search', {
                "keyword": tags[i],
              });
            } else if (itemType == 'search_with_namespace') {
              target = PageJumpTarget(context.key, 'search', {
                "keyword": "$name:$tags[i]",
              });
            } else {
              target = PageJumpTarget(context.key, itemType, null);
            }
            cs.add(CategoryItem(tags[i], target));
          }
          if (type == "fixed") {
            categoryParts.add(FixedCategoryPart(name, cs));
          } else if (type == "random") {
            categoryParts.add(
              RandomCategoryPart(name, cs, c["randomNumber"] ?? 1),
            );
          }
        }
      }

      return CategoryData(
        title: title,
        categories: categoryParts,
        enableRankingPage: enableRankingPage ?? false,
        key: title,
      );
    } finally {
      JSRef.freeRecursive(doc);
    }
  }

  CategoryComicsData? loadCategoryComicsData() {
    if (!context.checkExists("categoryComics")) return null;

    List<CategoryComicsOptions>? options;
    if (context.checkExists("categoryComics.optionList")) {
      options = <CategoryComicsOptions>[];
      for (var element in context.getValue("categoryComics.optionList") ?? []) {
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
          CategoryComicsOptions(
            element["label"] ?? "",
            map,
            List.from(element["notShowWhen"] ?? []),
            element["showWhen"] == null ? null : List.from(element["showWhen"]),
          ),
        );
      }
    }

    CategoryOptionsLoader? optionLoader;
    if (context.checkExists("categoryComics.optionLoader")) {
      optionLoader = (category, param) async {
        try {
          return await context.runReadCodeToCompletion<
            Res<List<CategoryComicsOptions>>
          >(
            """
          ${context.sourceExpression}.categoryComics.optionLoader(
            ${jsonEncode(category)}, ${jsonEncode(param)})
        """,
            consume: (res) {
              if (res is! List) {
                return Res.error(
                  "Invalid data:\nExpected: List\nGot: ${res.runtimeType}",
                );
              }
              var options = <CategoryComicsOptions>[];
              for (var element in res) {
                if (element is! Map) {
                  return Res.error(
                    "Invalid option data:\nExpected: Map\nGot: ${element.runtimeType}",
                  );
                }
                LinkedHashMap<String, String> map =
                    LinkedHashMap<String, String>();
                for (var option in element["options"] ?? []) {
                  if (option.isEmpty || !option.contains("-")) {
                    continue;
                  }
                  var split = option.split("-");
                  var key = split.removeAt(0);
                  var value = split.join("-");
                  map[key] = value;
                }
                options.add(
                  CategoryComicsOptions(
                    element["label"] ?? "",
                    map,
                    List.from(element["notShowWhen"] ?? []),
                    element["showWhen"] == null
                        ? null
                        : List.from(element["showWhen"]),
                  ),
                );
              }
              return Res(options);
            },
          );
        } catch (e, s) {
          Log.error("Data Analysis", "Failed to load category options.\n$e");
          return context.failureResult(e, s);
        }
      };
    }

    RankingData? rankingData;
    if (context.checkExists("categoryComics.ranking")) {
      var options = <String, String>{};
      for (var option in context.getValue("categoryComics.ranking.options")) {
        if (option.isEmpty || !option.contains("-")) {
          continue;
        }
        var split = option.split("-");
        var key = split.removeAt(0);
        var value = split.join("-");
        options[key] = value;
      }
      Future<Res<List<Comic>>> Function(String option, int page)? load;
      Future<Res<List<Comic>>> Function(String option, String? next)?
      loadWithNext;
      if (context.checkExists("categoryComics.ranking.load")) {
        load = (option, page) async {
          try {
            return await context.runReadCodeToCompletion<Res<List<Comic>>>("""
            ${context.sourceExpression}.categoryComics.ranking.load(
              ${jsonEncode(option)}, ${jsonEncode(page)})
          """, consume: (res) => context.parseComicListResult(res, 'maxPage'));
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return context.failureResult(e, s);
          }
        };
      } else {
        loadWithNext = (option, next) async {
          try {
            return await context.runReadCodeToCompletion<Res<List<Comic>>>("""
            ${context.sourceExpression}.categoryComics.ranking.loadWithNext(
              ${jsonEncode(option)}, ${jsonEncode(next)})
          """, consume: (res) => context.parseComicListResult(res, 'next'));
          } catch (e, s) {
            Log.error("Network", "$e\n$s");
            return context.failureResult(e, s);
          }
        };
      }
      rankingData = RankingData(options, load, loadWithNext);
    }

    if (options == null && optionLoader == null) {
      options = [];
    }

    return CategoryComicsData(
      options: options,
      optionsLoader: optionLoader,
      load: (category, param, options, page) async {
        try {
          return await context.runReadCodeToCompletion<Res<List<Comic>>>(
            """
              ${context.sourceExpression}.categoryComics.load(
                ${jsonEncode(category)},
                ${jsonEncode(param)},
                ${jsonEncode(options)},
                ${jsonEncode(page)}
              )
            """,
            consume: (res) => context.parseComicListResult(res, 'maxPage'),
          );
        } catch (e, s) {
          Log.error("Network", "$e\n$s");
          return context.failureResult(e, s);
        }
      },
      rankingData: rankingData,
    );
  }
}
