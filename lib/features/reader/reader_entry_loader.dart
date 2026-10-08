import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/history/history_api.dart';
import 'package:venera_next/features/local_comics/local_comics_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

/// Resolves initial reader metadata without owning a route or global manager.
/// A missing source falls back to the local catalog; a failed source does not.
class ReaderEntryLoader {
  const ReaderEntryLoader({
    required this.resolveComicLoader,
    required this.findHistory,
    required this.findLocalComic,
  });

  /// Null means the source is absent. An installed source without a details
  /// capability must return a failing callback, not pretend to be absent.
  final LoadComicFunc? Function(String sourceKey) resolveComicLoader;
  final History? Function(String id, ComicType type) findHistory;
  final LocalComic? Function(String id, ComicType type) findLocalComic;

  /// The caller owns [scope]. Cancellation rejects the result only after an
  /// already-started source call settles; this service does not create retries.
  Future<Res<ReaderProps>> load({
    required String id,
    required String sourceKey,
    required RequestScope scope,
  }) async {
    scope.check();
    final loadComic = resolveComicLoader(sourceKey);
    final type = ComicType.fromKey(sourceKey);
    final history = findHistory(id, type);
    if (loadComic == null) {
      final localComic = findLocalComic(id, type);
      if (localComic == null) {
        return const Res.error('comic not found');
      }
      return Res(
        ReaderProps(
          type: type,
          cid: id,
          name: localComic.title,
          chapters: localComic.chapters,
          history:
              history ?? History.fromModel(model: localComic, ep: 0, page: 0),
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    }
    final comic = await loadComic(id);
    scope.check();
    if (comic.error) return Res.fromErrorRes(comic);
    return Res(
      ReaderProps(
        type: type,
        cid: id,
        name: comic.data.title,
        chapters: comic.data.chapters,
        history:
            history ?? History.fromModel(model: comic.data, ep: 0, page: 0),
        author: comic.data.findAuthor() ?? '',
        tags: comic.data.plainTags,
      ),
    );
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
