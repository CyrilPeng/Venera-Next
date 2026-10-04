import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'reader_image_processing.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera_next/foundation/appdata.dart';

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  @override
  final bool enableResize;

  @protected
  File createLocalFile(String path) => File(path);

  @override
  bool get retryFileSystemErrors => !imageKey.startsWith('file://');

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      final file = createLocalFile(imageKey.substring(7));
      final exists = await file.exists();
      checkStop();
      if (exists) {
        imageBytes = await readFileBytesChecked(
          file,
          requireNonEmpty: true,
          checkStop: checkStop,
          cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
          canRetry: () => BaseImageProvider.canRetryAfterFailure(checkStop),
        );
      } else {
        throw FileSystemException('File not found', file.path);
      }
    } else {
      imageBytes = await readImageStream(
        ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid),
        cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
        checkStop: checkStop,
        onProgress: (event) => chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        ),
      );
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    checkStop();
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      imageBytes = await processReaderImageBytes(
        imageBytes,
        script: script,
        comicId: cid,
        episodeId: eid,
        page: page,
        sourceKey: sourceKey,
        checkStop: checkStop,
        cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
      );
    }
    return imageBytes;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "$imageKey@$sourceKey@$cid@$eid@$enableResize";
}
