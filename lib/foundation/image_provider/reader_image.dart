import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/missing_download_page.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'dart:async' show Future;
import 'dart:ui' show TargetImageSize;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'reader_image_processing.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'base_image_provider.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';
import 'package:venera_next/foundation/tv_reader_policy.dart';

class ReaderImageProvider extends BaseImageProvider<ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
    this.diagnostics,
    this.decodePixelBudget,
  }) : assert(decodePixelBudget == null || decodePixelBudget > 0);

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  @override
  final bool enableResize;
  final int? decodePixelBudget;

  @override
  TargetImageSize targetSizeForImage(int width, int height) {
    final budget = decodePixelBudget;
    if (budget == null) return super.targetSizeForImage(width, height);
    final size = TvReaderPolicy.decodeSize(width, height, pixelBudget: budget);
    return TargetImageSize(width: size.width, height: size.height);
  }

  @override
  final ReaderDiagnostics? diagnostics;

  @protected
  File createLocalFile(String path) => File(path);

  @override
  bool get retryFileSystemErrors =>
      !imageKey.startsWith('file://') &&
      !imageKey.startsWith(missingDownloadPagePrefix);

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    checkStop();
    if (imageKey.startsWith(missingDownloadPagePrefix)) {
      throw FileSystemException(
        'This page is missing. Retry missing pages in Downloads.'.tl,
      );
    }
    Uint8List? imageBytes;
    final readDiagnostic = diagnostics?.beginImageSpan(
      hashCode,
      imageKey.startsWith('file://')
          ? ReaderDiagnosticStage.localRead
          : ReaderDiagnosticStage.sourceRead,
    );
    try {
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
        throw OperationFailure.message("Error: Empty response body.");
      }
      checkStop();
      readDiagnostic?.finish(bytes: imageBytes.length);
    } catch (_) {
      readDiagnostic?.finish(success: false);
      rethrow;
    }
    if (GlobalPreferenceStore(
      appdata.settings,
    ).read(ImageProcessingPreferences.enabled)) {
      var script = GlobalPreferenceStore(
        appdata.settings,
      ).read(ImageProcessingPreferences.script);
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      final processingDiagnostic = diagnostics?.beginImageSpan(
        hashCode,
        ReaderDiagnosticStage.processingWait,
      );
      try {
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
        processingDiagnostic?.finish(bytes: imageBytes.length);
      } catch (_) {
        processingDiagnostic?.finish(success: false);
        rethrow;
      }
    }
    return imageBytes;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key =>
      "$imageKey@$sourceKey@$cid@$eid@$enableResize${decodePixelBudget == null ? '' : '@tv:$decodePixelBudget'}";
}
