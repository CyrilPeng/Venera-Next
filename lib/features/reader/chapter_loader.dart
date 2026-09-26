import 'dart:io';

import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/translations.dart';

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
Future<List<String>> loadReaderChapterImages({
  required String comicId,
  required ComicType type,
  required int chapter,
  required ComicChapters? chapters,
  void Function()? onOnlineFallback,
}) async {
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
  var missingLocalFiles = false;
  if (type == ComicType.local || downloaded) {
    try {
      final images = await manager.getImages(
        comicId,
        type,
        chapterId ?? chapter,
      );
      if (images.isEmpty) {
        throw FileSystemException(
          'No local comic images found',
          local?.baseDir,
        );
      }
      return images;
    } on FileSystemException catch (error, stack) {
      Log.error('Local chapter', {
        'comicId': comicId,
        'comicType': type.value,
        'chapterId': chapterId,
        'storageRoot': manager.path,
        'comicDirectory': local?.baseDir,
        'error': error.toString(),
      }, stack);
      if (source?.loadComicPages == null) {
        throw LocalComicFilesUnavailable(error.path ?? local!.baseDir);
      }
      missingLocalFiles = true;
    }
  }
  if (source?.loadComicPages == null) {
    throw 'Comic source is unavailable'.tl;
  }
  final result = await source!.loadComicPages!(comicId, chapterId);
  if (result.error) throw result.errorMessage!;
  if (missingLocalFiles) onOnlineFallback?.call();
  return result.data;
}
