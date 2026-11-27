import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async' show Completer, Future, FutureOr, StreamController;
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'base_image_provider.dart';
import 'image_provider_lifecycle.dart';

class CachedImageProvider extends BaseImageProvider<CachedImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const CachedImageProvider(
    this.url, {
    this.headers,
    this.sourceKey,
    this.cid,
    this.fallback,
    this.cacheKey,
    this.onVersionMissing,
  });

  final String url;

  final Map<String, String>? headers;

  final String? sourceKey;

  final String? cid;

  /// Refreshed covers use an immutable content version. A late ordinary image
  /// download cannot overwrite this version's disk or Flutter cache entry.
  final String? cacheKey;
  final VoidCallback? onVersionMissing;

  final FutureOr<Uint8List?> Function()? fallback;

  @protected
  File createLocalFile(String path) => File(path);

  static int loadingCount = 0;

  static const _kMaxLoadingCount = 8;

  static final _thumbnailLoadSlots = _AsyncSemaphore(_kMaxLoadingCount + 1);

  @visibleForTesting
  static Future<T> debugRunWithThumbnailSlot<T>(
    Future<T> Function() task, {
    void Function()? checkStop,
    Future<void>? cancelSignal,
  }) {
    return _runWithThumbnailSlot(
      task,
      checkStop: checkStop,
      cancelSignal: cancelSignal,
    );
  }

  static Future<T> _runWithThumbnailSlot<T>(
    Future<T> Function() task, {
    void Function()? checkStop,
    Future<void>? cancelSignal,
  }) {
    return _thumbnailLoadSlots.run(() async {
      checkStop?.call();
      loadingCount++;
      try {
        return await task();
      } finally {
        loadingCount--;
      }
    }, cancelSignal: cancelSignal);
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    return _runWithThumbnailSlot(
      () => _loadImage(chunkEvents, checkStop),
      checkStop: checkStop,
      cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
    );
  }

  Future<Uint8List> _loadImage(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    checkStop();
    if (cacheKey case final key?) {
      final file = await CacheManager().findCache(key);
      checkStop();
      if (file != null) {
        try {
          final bytes = await file.readAsBytes();
          checkStop();
          return bytes;
        } on FileSystemException {
          // Eviction can finish between finding the file and opening it.
        }
      }
      checkStop();
      onVersionMissing?.call();
      throw OperationFailure.message('Cover cache version is unavailable');
    }
    try {
      if (url.startsWith("file://")) {
        final file = createLocalFile(url.substring(7));
        final bytes = await file.readAsBytes();
        checkStop();
        return bytes;
      }
      final bytes = await readImageStream(
        ImageDownloader.loadThumbnail(url, sourceKey, cid),
        cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
        checkStop: checkStop,
        onProgress: (progress) => chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: progress.currentBytes,
            expectedTotalBytes: progress.totalBytes,
          ),
        ),
      );
      if (bytes != null) return bytes;
      throw OperationFailure.message("Error: Empty response body.");
    } catch (e) {
      if (BaseImageProvider.isCancellation(e) ||
          BaseImageProvider.isCleanupFailure(e) ||
          !BaseImageProvider.canRetryAfterFailure(checkStop)) {
        rethrow;
      }
      final fallbackImage = await fallback?.call();
      checkStop();
      if (fallbackImage != null) {
        if (fallbackImage.isNotEmpty) {
          return fallbackImage;
        }
      }
      rethrow;
    }
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key =>
      url +
      (sourceKey ?? "") +
      (cid ?? "") +
      (cacheKey == null ? '' : '@$cacheKey');
}

class _AsyncSemaphore {
  final int maxConcurrent;

  int _active = 0;

  final _waiters = Queue<Completer<bool>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<T> run<T>(
    Future<T> Function() task, {
    Future<void>? cancelSignal,
  }) async {
    if (!await _acquire(cancelSignal)) {
      throw const ImageProviderLoadCancelled();
    }
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<bool> _acquire(Future<void>? cancelSignal) {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(true);
    }
    final completer = Completer<bool>();
    _waiters.add(completer);
    cancelSignal?.then((_) {
      if (_waiters.remove(completer)) completer.complete(false);
    });
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(true);
      return;
    }
    _active--;
  }
}
