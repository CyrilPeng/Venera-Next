import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      var comicSource =
          history.type.comicSource ?? (throw "Comic source not found.");
      var comic = await comicSource.loadComicInfo!(history.id);
      checkStop();
      url = comic.data.cover;
      history.cover = url;
      HistoryManager().addHistory(history);
    }
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
