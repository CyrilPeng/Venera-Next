import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/request_scope.dart';

import 'chapter_image_loader.dart';

class LocalComicFilesUnavailable implements Exception {
  const LocalComicFilesUnavailable(this.path);

  final String path;

  @override
  String toString() {
    final message =
        'Local comic files are unavailable. Check the storage location or restore the files.'
            .tl;
    return '$message\n$path';
  }
}

/// Resolve downloaded chapters by ID, independently of the current source's
/// chapter order. Database download records do not guarantee files still exist.
/// Each call owns a child of [scope], propagating cancellation to source calls
/// and checking it before publishing results or online recovery callbacks.
Future<List<String>> loadReaderChapterImages({
  required String comicId,
  required ComicType type,
  required int chapter,
  required ComicChapters? chapters,
  void Function()? onOnlineFallback,
  RequestScope? scope,
}) async {
  scope?.check();
  final chapterId = chapters?.ids.elementAtOrNull(chapter - 1);
  if (chapters != null && chapterId == null) {
    throw RangeError('Invalid chapter');
  }
  final manager = LocalManager();
  final local = manager.find(comicId, type);
  final source = type == ComicType.local
      ? null
      : ComicSource.fromIntKey(type.value);
  final downloaded =
      local != null &&
      (chapters == null
          ? local.chapters == null
          : local.downloadedChapters.contains(chapterId));
  return ChapterImageLoader(
    readLocal: type == ComicType.local || downloaded
        ? () => manager.getImages(comicId, type, chapterId ?? chapter)
        : null,
    loadOnline: source?.loadComicPages == null
        ? null
        : () async {
            final result = await source!.loadComicPages!(comicId, chapterId);
            if (result.error) {
              final failure = result.failure;
              if (failure != null) {
                final cause = failure.cause ?? failure;
                final stack = failure.stackTrace;
                if (stack != null) Error.throwWithStackTrace(cause, stack);
                throw cause;
              }
              throw result.errorMessage!;
            }
            return result.data;
          },
    localPath: local?.baseDir ?? manager.path,
    onLocalFailure: (error, stack) => Log.error('Local chapter', {
      'comicId': comicId,
      'comicType': type.value,
      'chapterId': chapterId,
      'storageRoot': manager.path,
      'comicDirectory': local?.baseDir,
      'error': error.toString(),
    }, stack),
    localUnavailable: LocalComicFilesUnavailable.new,
    sourceUnavailable: 'Comic source is unavailable'.tl,
  ).load(scope: scope, onOnlineFallback: onOnlineFallback);
}
