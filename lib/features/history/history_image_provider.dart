import 'package:venera_next/features/history/history_api.dart';
import 'dart:async' show Future, Stream, StreamController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';

class HistoryImageProvider extends BaseImageProvider<HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  @protected
  Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey,
    String id,
  ) => ImageDownloader.loadThumbnail(url, sourceKey, id);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    checkStop();
    final id = history.id;
    final type = history.type;
    var url = history.cover;
    if (!url.contains('/')) {
      var localComic = LocalManager().find(id, type);
      if (localComic != null) {
        final bytes = await localComic.coverFile.readAsBytes();
        checkStop();
        return bytes;
      }
      var comicSource = type.comicSource ?? (throw "Comic source not found.");
      final updateMetadata = HistoryManager().metadataUpdaterFor(history);
      var comic = await comicSource.loadComicInfo!(id);
      checkStop();
      url = comic.data.cover;
      final updated = await updateMetadata(cover: url);
      if (updated && history.id == id && history.type == type) {
        history.cover = url;
      }
      checkStop();
    }
    checkStop();
    final bytes = await readImageStream(
      loadThumbnail(url, type.sourceKey, id),
      cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
      checkStop: checkStop,
      onProgress: (progress) => chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      ),
    );
    checkStop();
    if (bytes == null) throw "Error: Empty response body.";
    return bytes;
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
