import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/reader/reader.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';

void openLocalComic(LocalComic comic) {
  final history = HistoryManager().find(comic.id, comic.comicType);
  final start = resolveLocalReadingStart(
    chapters: comic.chapters,
    downloadedChapters: comic.downloadedChapters,
    historyChapter: history?.ep,
    historyPage: history?.page,
    historyGroup: history?.group,
  );
  App.rootContext.to(
    () => Reader(
      type: comic.comicType,
      cid: comic.id,
      name: comic.title,
      chapters: comic.chapters,
      initialChapter: start.chapter,
      initialPage: start.page,
      initialChapterGroup: start.group,
      history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
      author: comic.subtitle,
      tags: comic.tags,
    ),
  );
}
