import 'page_layout.dart';
import 'reader_controller.dart';

/// Configuration snapshot for one gallery build. Content comes from the
/// controller's immutable chapter snapshot; scroll position stays in navigation.
class ReaderGalleryData {
  const ReaderGalleryData({
    required this.content,
    required this.layout,
    required this.vertical,
    required this.reverse,
    required this.commentsAtEnd,
    required this.firstChapter,
    required this.lastChapter,
    required this.preloadCount,
    required this.doubleTapCollect,
    required this.centerLongPressZoom,
    required this.pageAnimation,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
  });

  final ReaderContentState content;
  final ReaderPageLayout layout;
  final bool vertical;
  final bool reverse;
  final bool commentsAtEnd;
  final bool firstChapter;
  final bool lastChapter;
  final int preloadCount;
  final bool doubleTapCollect;
  final bool centerLongPressZoom;
  final bool pageAnimation;
  final String? sourceKey;
  final String comicId;
  final String chapterId;

  List<String> get images => content.images ?? const [];
  int get imagePages => layout.pageCount(images.length);
  int get totalPages => imagePages + (commentsAtEnd ? 1 : 0);
  bool isCommentsPage(int page) => commentsAtEnd && page == imagePages + 1;
}
