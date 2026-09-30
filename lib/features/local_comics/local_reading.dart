import 'package:venera_next/features/comic_source/comic_source_api.dart';

typedef LocalReadingStart = ({int? chapter, int? page, int? group});

/// Resolve persisted history and downloaded chapter IDs without navigating.
LocalReadingStart resolveLocalReadingStart({
  required ComicChapters? chapters,
  required Iterable<String> downloadedChapters,
  int? historyChapter,
  int? historyPage,
  int? historyGroup,
}) {
  int? firstDownloadedChapter;
  int? firstDownloadedGroup;
  if (downloadedChapters.isNotEmpty && chapters != null) {
    if (chapters.isGrouped) {
      // Preserve the existing group selection rule during structural migration:
      // the first downloaded chapter in the last matching group wins.
      for (var i = 0; i < chapters.groupCount; i++) {
        final keys = chapters.getGroupByIndex(i).keys.toList();
        for (var j = 0; j < keys.length; j++) {
          if (downloadedChapters.contains(keys[j])) {
            firstDownloadedChapter = j + 1;
            firstDownloadedGroup = i + 1;
            break;
          }
        }
      }
    } else {
      final keys = chapters.allChapters.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        if (downloadedChapters.contains(keys[i])) {
          firstDownloadedChapter = i + 1;
          break;
        }
      }
    }
  }
  return (
    chapter: historyChapter ?? firstDownloadedChapter,
    page: historyPage,
    group: historyGroup ?? firstDownloadedGroup,
  );
}
