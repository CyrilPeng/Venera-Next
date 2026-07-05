import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/js_engine.dart';

import 'models.dart';

Map<String, dynamic>? normalizeComicSourceLoadingConfig(dynamic value) {
  return normalizeComicSourceStringKeyedMap(value);
}

Map<String, dynamic>? normalizeComicSourceStringKeyedMap(dynamic value) {
  if (value is! Map) {
    return null;
  }
  var map = <String, dynamic>{};
  for (var entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      return null;
    }
    map[key] = entry.value;
  }
  return map;
}

List<String>? normalizeComicSourceStringList(dynamic value) {
  if (value is! List) {
    return null;
  }
  var list = <String>[];
  for (var item in value) {
    if (item is! String) {
      return null;
    }
    list.add(item);
  }
  return list;
}

List<Map<String, dynamic>>? _normalizeComicSourceStringKeyedMapList(
  dynamic value,
) {
  if (value is! List) {
    return null;
  }
  var list = <Map<String, dynamic>>[];
  for (var item in value) {
    final map = normalizeComicSourceStringKeyedMap(item);
    if (map == null) {
      return null;
    }
    list.add(map);
  }
  return list;
}

List<Comic>? normalizeComicSourceComicList(dynamic value, String sourceKey) {
  final items = _normalizeComicSourceStringKeyedMapList(value);
  if (items == null) return null;
  var comics = <Comic>[];
  for (var item in items) {
    comics.add(Comic.fromJson(item, sourceKey));
  }
  return comics;
}

Map<String, List<String>>? _normalizeComicSourceTagMap(dynamic value) {
  if (value is! Map) {
    return null;
  }
  var tags = <String, List<String>>{};
  for (var entry in value.entries) {
    final key = entry.key;
    final tagList = entry.value;
    if (tagList is! List) {
      continue;
    }
    if (key is! String) {
      return null;
    }
    final normalized = normalizeComicSourceStringList(tagList);
    if (normalized == null) {
      return null;
    }
    tags[key] = normalized;
  }
  return tags;
}

Map<String, dynamic>? normalizeComicSourceComicDetails(
  dynamic value,
  String sourceKey,
  String comicId,
) {
  final data = normalizeComicSourceStringKeyedMap(value);
  if (data == null) return null;

  final tags = _normalizeComicSourceTagMap(data["tags"]);
  if (tags == null) return null;
  data["tags"] = tags;

  if (data["thumbnails"] != null) {
    final thumbnails = normalizeComicSourceStringList(data["thumbnails"]);
    if (thumbnails == null) return null;
    data["thumbnails"] = thumbnails;
  }

  if (data["recommend"] != null) {
    final recommend = _normalizeComicSourceStringKeyedMapList(
      data["recommend"],
    );
    if (recommend == null) return null;
    data["recommend"] = recommend;
  }

  if (data["comments"] != null) {
    final comments = _normalizeComicSourceStringKeyedMapList(data["comments"]);
    if (comments == null) return null;
    data["comments"] = comments;
  }

  data["sourceKey"] = sourceKey;
  data["comicId"] = comicId;
  return data;
}

List<Comment>? _normalizeComicSourceCommentList(dynamic value) {
  final items = _normalizeComicSourceStringKeyedMapList(value);
  if (items == null) return null;
  return items.map(Comment.fromJson).toList();
}

({Map<String, dynamic> data, List<Comment> comments})?
normalizeComicSourceCommentsResult(dynamic value) {
  final data = normalizeComicSourceStringKeyedMap(value);
  final comments = _normalizeComicSourceCommentList(data?["comments"]);
  if (data == null || comments == null) {
    return null;
  }
  return (data: data, comments: comments);
}

List<ArchiveInfo>? normalizeComicSourceArchiveList(dynamic value) {
  final items = _normalizeComicSourceStringKeyedMapList(value);
  if (items == null) return null;
  return items.map(ArchiveInfo.fromJson).toList();
}

String? normalizeComicSourceArchiveDownloadUrl(dynamic value) {
  return value is String ? value : null;
}

({Map<String, dynamic> data, List<String> items})?
normalizeComicSourceStringListResult(dynamic value, String key) {
  final data = normalizeComicSourceStringKeyedMap(value);
  final items = normalizeComicSourceStringList(data?[key]);
  if (data == null || items == null) {
    return null;
  }
  return (data: data, items: items);
}

Map<String, Map<String, dynamic>>? normalizeComicSourceSettings(dynamic value) {
  if (value is! Map) {
    return null;
  }
  var newMap = <String, Map<String, dynamic>>{};
  for (var e in value.entries) {
    final key = e.key;
    final value = e.value;
    if (key is! String || value is! Map) {
      continue;
    }
    var v = <String, dynamic>{};
    for (var e2 in value.entries) {
      final itemKey = e2.key;
      if (itemKey is! String) {
        continue;
      }
      var v2 = e2.value;
      if (v2 is JSInvokable) {
        v2 = JSAutoFreeFunction(v2);
      }
      v[itemKey] = v2;
    }
    newMap[key] = v;
  }
  return newMap;
}
