import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show ComicChapters;
import 'package:venera_next/network/request_scope.dart';

/// Original chapter order and loading capability for one reader target.
/// Accepted calls keep their complete Future even after the target retires.
class ReaderChapterRequest {
  ReaderChapterRequest({
    required this.identity,
    required ComicChapters? chapters,
    required this.isCurrent,
    required this.canInteract,
    required Future<List<String>> Function(int, ComicChapters?, RequestScope)
    load,
  }) : _chapters = _freeze(chapters),
       _load = load;

  final Object identity;
  final ComicChapters? _chapters;
  final bool Function() isCurrent;
  final bool Function() canInteract;
  final Future<List<String>> Function(int, ComicChapters?, RequestScope) _load;

  String chapterId(int chapter) =>
      _chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';
  String? chapterTitle(int chapter) =>
      _chapters?.titles.elementAtOrNull(chapter - 1);

  Future<List<String>> load(int chapter, RequestScope scope) async {
    void check() {
      if (!isCurrent()) scope.cancel();
      scope.check();
    }

    check();
    final List<String> images;
    try {
      images = await _load(chapter, _chapters, scope);
    } finally {
      // Preserve an original read failure while marking its retired owner.
      // The caller's ImageWork then retains it instead of publishing old UI.
      if (!isCurrent()) scope.cancel();
    }
    check();
    return images;
  }

  static ComicChapters? _freeze(ComicChapters? source) {
    if (source == null) return null;
    return source.isGrouped
        ? ComicChapters.grouped(
            Map.unmodifiable({
              for (final group in source.groups)
                group: Map<String, String>.unmodifiable(source.getGroup(group)),
            }),
          )
        : ComicChapters(
            Map.unmodifiable(Map.fromIterables(source.ids, source.titles)),
          );
  }
}
