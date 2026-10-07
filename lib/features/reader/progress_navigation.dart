/// The image-page range and chapter navigation represented by one progress bar.
/// Admission belongs to the original content owner, never to the latest widget.
class ReaderProgressRequest {
  const ReaderProgressRequest({
    required this.identity,
    required this.page,
    required this.maxPage,
    required this.chapter,
    required this.maxChapter,
    required this.reversed,
    required bool Function() isCurrent,
    required bool Function(int page, {bool animated}) toPage,
    required bool Function(int chapter) toChapter,
  }) : _isCurrent = isCurrent,
       _toPage = toPage,
       _toChapter = toChapter;

  final Object identity;
  final int page, maxPage, chapter, maxChapter;
  final bool reversed;
  final bool Function() _isCurrent;
  final bool Function(int page, {bool animated}) _toPage;
  final bool Function(int chapter) _toChapter;

  bool selectPage(int page) {
    // The comments tail is deliberately outside the progress slider's range.
    if (!_isCurrent() || page < 1 || page > maxPage) return false;
    return _toPage(page, animated: false);
  }

  bool previous() => _edge(reversed ? 1 : -1);
  bool next() => _edge(reversed ? -1 : 1);

  bool _edge(int direction) {
    if (!_isCurrent()) return false;
    final target = chapter + direction;
    if (target >= 1 && target <= maxChapter) return _toChapter(target);
    return _toPage(direction < 0 ? 1 : maxPage, animated: true);
  }
}
