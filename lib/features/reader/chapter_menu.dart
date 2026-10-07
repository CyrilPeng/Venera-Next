import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicChapters;

/// Immutable chapters with global indices, including repeated IDs across groups.
class ReaderChapterMenuData {
  factory ReaderChapterMenuData(
    ComicChapters source, {
    required int currentChapter,
    Iterable<String> downloaded = const [],
  }) {
    final downloadedIds = downloaded.toSet();
    var index = 0;
    ReaderChapterGroup group(
      String? name,
      Iterable<MapEntry<String, String>> entries,
    ) => ReaderChapterGroup._(
      name,
      List.unmodifiable([
        for (final entry in entries)
          ReaderChapterEntry._(
            ++index,
            entry.key,
            entry.value,
            downloadedIds.contains(entry.key),
          ),
      ]),
    );
    final groups = List<ReaderChapterGroup>.unmodifiable(
      source.isGrouped
          ? [
              for (final name in source.groups)
                group(name, source.getGroup(name).entries),
            ]
          : [group(null, Map.fromIterables(source.ids, source.titles).entries)],
    );
    var initialGroup = groups.indexWhere(
      (group) => group.entries.any((entry) => entry.index == currentChapter),
    );
    if (initialGroup < 0) {
      initialGroup = groups.indexWhere((group) => group.entries.isNotEmpty);
    }
    return ReaderChapterMenuData._(
      source.isGrouped,
      groups,
      currentChapter,
      initialGroup < 0 ? 0 : initialGroup,
      index,
    );
  }

  const ReaderChapterMenuData._(
    this.isGrouped,
    this.groups,
    this.currentChapter,
    this.initialGroup,
    this.length,
  );
  final bool isGrouped;
  final List<ReaderChapterGroup> groups;
  final int currentChapter;
  final int initialGroup;
  final int length;

  /// Source maps are mutable, so identity alone cannot validate a saved index.
  bool matches(ComicChapters source) {
    if (source.isGrouped != isGrouped) return false;
    final names = source.isGrouped ? source.groups.toList() : <String?>[null];
    if (names.length != groups.length) return false;
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      if (group.name != names[i]) return false;
      final ids =
          (isGrouped ? source.getGroup(names[i]!).keys : source.ids).iterator;
      final titles =
          (isGrouped ? source.getGroup(names[i]!).values : source.titles)
              .iterator;
      for (final entry in group.entries) {
        if (!ids.moveNext() ||
            !titles.moveNext() ||
            entry.id != ids.current ||
            entry.title != titles.current) {
          return false;
        }
      }
      if (ids.moveNext() || titles.moveNext()) return false;
    }
    return true;
  }
}

class ReaderChapterGroup {
  const ReaderChapterGroup._(this.name, this.entries);
  final String? name;
  final List<ReaderChapterEntry> entries;
}

class ReaderChapterEntry {
  const ReaderChapterEntry._(this.index, this.id, this.title, this.downloaded);
  final int index;
  final String id;
  final String title;
  final bool downloaded;
}

/// Bound by the reader to its original content and session.
class ReaderChapterMenuRequest {
  ReaderChapterMenuRequest({
    required this.data,
    required bool Function() isCurrent,
    required bool Function(int) select,
  }) : _isCurrent = isCurrent,
       _select = select;
  final ReaderChapterMenuData data;
  final bool Function() _isCurrent;
  final bool Function(int) _select;

  bool select(int chapter) {
    if (chapter < 1 || chapter > data.length || !_isCurrent()) return false;
    return _select(chapter);
  }
}
