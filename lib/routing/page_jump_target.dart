import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/discovery/discovery.dart';
import 'package:venera_next/features/search/search.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/log.dart';

String? _parseJumpUrl(dynamic raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return trimmed;
}

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
    } else if (page == "url") {
      final rawUrl = attributes?["url"];
      if (rawUrl == null || (rawUrl is String && rawUrl.trim().isEmpty)) {
        Log.error("Page Jump", "URL is required");
        return;
      }
      final validUrl = _parseJumpUrl(rawUrl);
      if (validUrl == null) {
        Log.error("Page Jump", "Invalid URL");
        return;
      }
      unawaited(launchUrlString(validUrl));
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
