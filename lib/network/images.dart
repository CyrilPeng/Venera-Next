import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/consts.dart';
import 'package:venera_next/foundation/image_processing.dart';

import 'app_dio.dart';
import 'image_http_client.dart';
import 'image_loading_config.dart';
import 'request_scope.dart';
import 'shared_image_requests.dart';

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

typedef ComicImageLoader =
    Stream<ImageDownloadProgress> Function(
      String imageKey,
      String? sourceKey,
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
  ) async {
    final owner = ImageLoadingConfigOwner(onResponse);
    Object? failure;
    StackTrace? failureStack;
    try {
      return await _applyImageResponseCallback(onResponse, buffer, owner);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      rethrow;
    } finally {
      owner.dispose(cause: failure, stackTrace: failureStack);
    }
  }

  static Future<List<int>> _applyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
    ImageLoadingConfigOwner owner,
  ) async {
    dynamic result = onResponse([Uint8List.fromList(buffer)]);
    if (result is Future) result = await result;
    if (result is List<int>) {
      return result;
    }
    const error = 'Error: Invalid onResponse result.';
    owner.discard(result, cause: error, stackTrace: StackTrace.current);
    throw error;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugResolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) async {
    final owner = ImageLoadingConfigOwner(onLoadFailed);
    Object? failure;
    StackTrace? failureStack;
    try {
      final config = await _resolveImageLoadFailure(onLoadFailed, owner);
      owner.replace(config);
      owner.detach();
      return config;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      rethrow;
    } finally {
      owner.dispose(cause: failure, stackTrace: failureStack);
    }
  }

  static Future<Map<String, dynamic>?> _resolveImageLoadFailure(
    JSInvokable onLoadFailed,
    ImageLoadingConfigOwner owner, {
    Object? cause,
    StackTrace? stackTrace,
  }) async {
    dynamic result = onLoadFailed([]);
    if (result is Future) result = await result;
    final config = _normalizeImageLoadConfig(result);
    if (config == null) {
      owner.discard(result, cause: cause, stackTrace: stackTrace);
    }
    return config;
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

  static ({Object error, StackTrace stack}) _imageFailure(
    Object error,
    StackTrace stack,
    RequestScope? scope,
    ImageLoadingConfigOwner owner,
  ) {
    if (error is ImageHttpCleanupFailure) {
      try {
        // The typed wrapper must not hide a rejected graph from its owner.
        owner.discard(error.cause, cause: error, stackTrace: stack);
      } catch (cleanup, cleanupStack) {
        return (error: cleanup, stack: cleanupStack);
      }
      return (error: error, stack: stack);
    }
    if (scope?.isCancelled == true &&
        error is! ImageLoadingConfigFailure &&
        error is! ImageLoadingConfigCleanupFailure) {
      try {
        // A callback may reject after cancellation with fresh native refs.
        // Release them before replacing its error with normal cancellation.
        owner.discard(error, cause: error, stackTrace: stack);
        scope!.check();
      } catch (cancelOrCleanup, finalStack) {
        return (error: cancelOrCleanup, stack: finalStack);
      }
    }
    return (error: error, stack: stack);
  }

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) => _requests.open((scope) => _loadThumbnail(url, sourceKey, cid, scope));

  static Stream<ImageDownloadProgress> _loadThumbnail(
    String url,
    String? sourceKey,
    String? cid,
    RequestScope scope,
  ) async* {
    scope.check();
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    scope.check();
    if (cache != null) {
      var data = await cache.readAsBytes();
      scope.check();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs = await _resolveImageConfig(
        () async =>
            await _thumbnailLoadingConfigResolver?.call(sourceKey, url) ?? {},
        scope,
      );
    }
    final owner = ImageLoadingConfigOwner(configs);
    Object? failure;
    StackTrace? failureStack;
    try {
      scope.check();
      configs['headers'] ??= {};
      if (configs['headers']['user-agent'] == null &&
          configs['headers']['User-Agent'] == null) {
        configs['headers']['user-agent'] = webUA;
      }

      if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
          sourceKey != null &&
          cid != null) {
        final coverUrl = await _thumbnailCoverResolver?.call(sourceKey, cid);
        scope.check();
        if (coverUrl != null) {
          yield* _loadThumbnail(coverUrl, sourceKey, null, scope);
          return;
        }
      }

      final http = ImageHttpClient(
        AppDio(
          BaseOptions(
            headers: Map<String, dynamic>.from(configs['headers']),
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        ),
      );

      await for (final event in http.run<ImageDownloadProgress>((dio) async* {
        String requestUrl = configs['url'] ?? url;
        if (requestUrl.startsWith('//')) {
          requestUrl = 'https:$requestUrl';
        }
        var req = await dio.request<ResponseBody>(
          requestUrl,
          data: configs['data'],
          cancelToken: scope.cancelToken,
        );
        scope.check();
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        var buffer = <int>[];
        await for (var data in stream) {
          scope.check();
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
            owner,
          );
        }

        scope.check();
        await CacheManager().writeCache(cacheKey, buffer);
        scope.check();
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: buffer.length,
          imageBytes: Uint8List.fromList(buffer),
        );
      })) {
        yield event;
      }
    } catch (error, stack) {
      final result = _imageFailure(error, stack, scope, owner);
      failure = result.error;
      failureStack = result.stack;
      Error.throwWithStackTrace(result.error, result.stack);
    } finally {
      owner.dispose(cause: failure, stackTrace: failureStack);
    }
  }

  static final _requests = SharedImageRequests<ImageDownloadProgress>();

  /// Cancel and join shared, independent and retired image downloads.
  static Future<void> cancelAllLoadingImages() => _requests.cancelAll();

  static Future<void Function()> prepareForExit() => _requests.prepareForExit();

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    return _requests.open(
      (scope) => _loadComicImage(imageKey, sourceKey, cid, eid, scope: scope),
      key: cacheKey,
    );
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return _requests.open(
      (scope) => _loadComicImage(imageKey, sourceKey, cid, eid, scope: scope),
    );
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    RequestScope? scope,
  }) async* {
    scope?.check();
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = await CacheManager().findCache(cacheKey);

    scope?.check();
    if (cache != null) {
      var data = await cache.readAsBytes();
      scope?.check();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
      );
      return;
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      Future<Map<String, dynamic>> resolveConfig() async =>
          await _comicImageLoadingConfigResolver?.call(
            sourceKey,
            imageKey,
            cid,
            eid,
          ) ??
          {};
      configs = await _resolveImageConfig(resolveConfig, scope);
    }
    // Adopt the complete result before checking cancellation or interpreting
    // headers: even an unused callback must be released on those early exits.
    final owner = ImageLoadingConfigOwner(configs);
    Object? failure;
    StackTrace? failureStack;
    try {
      var retriesRemaining = 5;
      while (true) {
        try {
          scope?.check();
          configs['headers'] ??= {'user-agent': webUA};

          final http = ImageHttpClient(
            AppDio(
              BaseOptions(
                headers: configs['headers'],
                method: configs['method'] ?? 'GET',
                responseType: ResponseType.stream,
              ),
            ),
          );

          await for (final event in http.run<ImageDownloadProgress>((
            dio,
          ) async* {
            var req = await dio.request<ResponseBody>(
              configs['url'] ?? imageKey,
              data: configs['data'],
              cancelToken: scope?.cancelToken,
            );
            scope?.check();
            var stream =
                req.data?.stream ?? (throw "Error: Empty response body.");
            int? expectedBytes = req.data!.contentLength;
            if (expectedBytes == -1) {
              expectedBytes = null;
            }
            var buffer = <int>[];
            await for (var data in stream) {
              scope?.check();
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
                owner,
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

            scope?.check();
            await CacheManager().writeCache(cacheKey, data);
            scope?.check();
            yield ImageDownloadProgress(
              currentBytes: data.length,
              totalBytes: data.length,
              imageBytes: data,
            );
          })) {
            yield event;
          }
          return;
        } catch (error, stack) {
          // Retrying a request cannot repair a failed reference release. Keep
          // that failure observable even if a fallback download would succeed.
          if (error is ImageLoadingConfigFailure ||
              error is ImageLoadingConfigCleanupFailure ||
              error is ImageHttpCleanupFailure) {
            rethrow;
          }
          // Keep the original rejected graph until the outer owner can release
          // its references. Replacing it here with cancellation loses that graph.
          if (scope?.isCancelled == true) rethrow;
          final onLoadFailedCallback = configs['onLoadFailed'];
          if (onLoadFailedCallback is! JSInvokable ||
              !_shouldRetryImageLoad(
                retriesRemaining: retriesRemaining,
                hasOnLoadFailed: true,
              )) {
            rethrow;
          }
          retriesRemaining--;
          owner.discard(error, cause: error, stackTrace: stack);
          final newConfig = await _resolveImageLoadFailure(
            onLoadFailedCallback,
            owner,
            cause: error,
            stackTrace: stack,
          );
          if (newConfig == null) {
            rethrow;
          }
          // New results can alias the old callbacks. Transfer before release,
          // and retain the new config even if retiring the old one fails.
          owner.replace(newConfig);
          configs = newConfig;
        }
      }
    } catch (error, stack) {
      final result = _imageFailure(error, stack, scope, owner);
      failure = result.error;
      failureStack = result.stack;
      Error.throwWithStackTrace(result.error, result.stack);
    } finally {
      owner.dispose(cause: failure, stackTrace: failureStack);
    }
  }

  static Future<Map<String, dynamic>> _resolveImageConfig(
    Future<Map<String, dynamic>> Function() resolve,
    RequestScope? scope,
  ) async {
    if (scope == null) return resolve();
    Future<Map<String, dynamic>>? resolving;
    try {
      return await scope.run(() => resolving = resolve());
    } catch (_) {
      if (scope.isCancelled && resolving != null) {
        Map<String, dynamic>? discarded;
        try {
          // The cancellation race only ends the caller's wait. Keep ownership
          // of the actual configuration Promise until its result is released.
          discarded = await resolving;
        } catch (error, stack) {
          if (error is ImageLoadingConfigFailure ||
              error is ImageLoadingConfigCleanupFailure) {
            // The parser already released its rejected graph. Its cleanup
            // diagnostics must remain visible to the cancellation waiter.
            rethrow;
          }
          // Custom resolvers can reject with raw reference containers too.
          // Suppress the source failure only after those references are freed.
          ImageLoadingConfigOwner(
            error,
          ).dispose(cause: error, stackTrace: stack);
        }
        discardImageLoadingConfig(discarded);
      }
      rethrow;
    }
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
