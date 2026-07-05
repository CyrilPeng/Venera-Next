import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/image_processing.dart';

import 'app_dio.dart';

typedef ThumbnailLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(String sourceKey, String url);

typedef ThumbnailCoverResolver =
    FutureOr<String?> Function(String sourceKey, String cid);

typedef ComicImageLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(
      String sourceKey,
      String imageKey,
      String cid,
      String eid,
    );

abstract class ImageDownloader {
  static ThumbnailLoadingConfigResolver? _thumbnailLoadingConfigResolver;

  static ThumbnailCoverResolver? _thumbnailCoverResolver;

  static ComicImageLoadingConfigResolver? _comicImageLoadingConfigResolver;

  static void configureSourceImageLoading({
    ThumbnailLoadingConfigResolver? thumbnailLoadingConfig,
    ThumbnailCoverResolver? thumbnailCover,
    ComicImageLoadingConfigResolver? comicImageLoadingConfig,
  }) {
    _thumbnailLoadingConfigResolver = thumbnailLoadingConfig;
    _thumbnailCoverResolver = thumbnailCover;
    _comicImageLoadingConfigResolver = comicImageLoadingConfig;
  }

  @visibleForTesting
  static void debugResetSourceImageLoading() {
    configureSourceImageLoading();
  }

  @visibleForTesting
  static Stream<ImageDownloadProgress> Function(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  )?
  debugLoadComicImageUnwrapped;

  @visibleForTesting
  static bool debugShouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return _shouldRetryImageLoad(
      retriesRemaining: retriesRemaining,
      hasOnLoadFailed: hasOnLoadFailed,
    );
  }

  static bool _shouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return retriesRemaining > 0 && hasOnLoadFailed;
  }

  @visibleForTesting
  static Future<List<int>> debugApplyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) {
    return _applyImageResponseCallback(onResponse, buffer);
  }

  static Future<List<int>> _applyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) async {
    try {
      dynamic result = onResponse([Uint8List.fromList(buffer)]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        return result;
      }
      throw "Error: Invalid onResponse result.";
    } finally {
      onResponse.free();
    }
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugResolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) {
    return _resolveImageLoadFailure(onLoadFailed);
  }

  static Future<Map<String, dynamic>?> _resolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) async {
    try {
      dynamic result = onLoadFailed([]);
      if (result is Future) {
        result = await result;
      }
      return _normalizeImageLoadConfig(result);
    } finally {
      onLoadFailed.free();
    }
  }

  static Map<String, dynamic>? _normalizeImageLoadConfig(dynamic result) {
    if (result is! Map) {
      return null;
    }
    final config = <String, dynamic>{};
    for (final entry in result.entries) {
      final key = entry.key;
      if (key is! String) {
        return null;
      }
      config[key] = entry.value;
    }
    return config;
  }

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs =
          await _thumbnailLoadingConfigResolver?.call(sourceKey, url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null &&
        cid != null) {
      final coverUrl = await _thumbnailCoverResolver?.call(sourceKey, cid);
      if (coverUrl != null) {
        yield* loadThumbnail(coverUrl, sourceKey);
        return;
      }
    }

    var dio = AppDio(
      BaseOptions(
        headers: Map<String, dynamic>.from(configs['headers']),
        method: configs['method'] ?? 'GET',
        responseType: ResponseType.stream,
      ),
    );

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(
      requestUrl,
      data: configs['data'],
    );
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    if (configs['onResponse'] is JSInvokable) {
      buffer = await _applyImageResponseCallback(
        configs['onResponse'] as JSInvokable,
        buffer,
      );
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values.toList()) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final activeStream = _loadingImages[cacheKey];
    if (activeStream != null) {
      if (!activeStream.isClosed) {
        return activeStream.stream;
      }
      _loadingImages.remove(cacheKey);
    }
    final debugLoader = debugLoadComicImageUnwrapped;
    final stream = _StreamWrapper<ImageDownloadProgress>(
      debugLoader?.call(imageKey, sourceKey, cid, eid) ??
          _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        if (identical(_loadingImages[cacheKey], wrapper)) {
          _loadingImages.remove(cacheKey);
        }
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final debugLoader = debugLoadComicImageUnwrapped;
    if (debugLoader != null) {
      return debugLoader(imageKey, sourceKey, cid, eid);
    }
    return _loadComicImage(imageKey, sourceKey, cid, eid);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    if (cache != null) {
      var data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    JSInvokable? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs =
          await _comicImageLoadingConfigResolver?.call(
            sourceKey,
            imageKey,
            cid,
            eid,
          ) ??
          {};
    }
    var retriesRemaining = 5;
    while (true) {
      try {
        configs['headers'] ??= {'user-agent': webUA};

        final onLoadFailedConfig = configs['onLoadFailed'];
        onLoadFailed = onLoadFailedConfig is JSInvokable
            ? onLoadFailedConfig
            : null;

        var dio = AppDio(
          BaseOptions(
            headers: configs['headers'],
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        var req = await dio.request<ResponseBody>(
          configs['url'] ?? imageKey,
          data: configs['data'],
        );
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          buffer.addAll(data);
          yield ImageDownloadProgress(
            currentBytes: buffer.length,
            totalBytes: expectedBytes,
          );
        }

        if (configs['onResponse'] is JSInvokable) {
          buffer = await _applyImageResponseCallback(
            configs['onResponse'] as JSInvokable,
            buffer,
          );
        }

        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        await CacheManager().writeCache(cacheKey, data);
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback == null ||
            !_shouldRetryImageLoad(
              retriesRemaining: retriesRemaining,
              hasOnLoadFailed: true,
            )) {
          rethrow;
        }
        retriesRemaining--;
        onLoadFailed = null;
        var newConfig = await _resolveImageLoadFailure(onLoadFailedCallback);
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
      } finally {
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback != null) {
          onLoadFailed = null;
          onLoadFailedCallback.free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController<T>> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  StreamSubscription<T>? _subscription;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() {
    _subscription = _stream.listen(
      (data) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        }
      },
      onDone: _close,
    );
  }

  void _close() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    _subscription = null;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
      if (controllers.isEmpty) {
        cancel();
      }
    };
    return controller.stream;
  }

  void cancel() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    final subscription = _subscription;
    _subscription = null;
    onClosed(this);
    if (subscription == null) {
      return;
    }
    unawaited(subscription.cancel());
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}
