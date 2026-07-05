import 'package:flutter/widgets.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/discovery/discovery.dart';
import 'package:venera_next/features/search/search.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';

extension PageJumpTargetNavigation on PageJumpTarget {
  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: List.from(attributes?["options"] ?? []),
        ),
      );
    } else if (page == "category") {
      var key = ComicSource.find(sourceKey)!.categoryData!.key;
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category:
              attributes?["category"] ??
              (throw ArgumentError("Category name is required")),
          options: List.from(attributes?["options"] ?? []),
          param: attributes?["param"],
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
