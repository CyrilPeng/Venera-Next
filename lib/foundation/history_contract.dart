import 'comic_type.dart';

typedef HistoryType = ComicType;

/// Minimal comic metadata required to create or update a reading history item.
abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}
