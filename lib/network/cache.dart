import 'dart:typed_data';
import 'package:dio/dio.dart';

import 'json_response.dart';

class NetworkCache {
  final Uri uri;

  final Map<String, dynamic> requestHeaders;

  final Map<String, List<String>> responseHeaders;

  final Object? data;

  final DateTime time;

  final int size;

  final ResponseType? responseType;

  const NetworkCache({
    required this.uri,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.data,
    required this.time,
    required this.size,
    this.responseType,
  });
}

class NetworkCacheManager {
  NetworkCacheManager._();

  static final NetworkCacheManager instance = NetworkCacheManager._();

  factory NetworkCacheManager() => instance;

  final Map<Uri, NetworkCache> _cache = {};

  int size = 0;

  NetworkCache? getCache(Uri uri) {
    return _cache[uri];
  }

  static const _maxCacheSize = 10 * 1024 * 1024;

  void setCache(NetworkCache cache) {
    if (_cache.containsKey(cache.uri)) {
      size -= _cache[cache.uri]!.size;
      _cache.remove(cache.uri);
    }
    if (cache.size > _maxCacheSize) {
      return;
    }
    while (_cache.isNotEmpty && size + cache.size > _maxCacheSize) {
      size -= _cache.values.first.size;
      _cache.remove(_cache.keys.first);
    }
    _cache[cache.uri] = cache;
    size += cache.size;
  }

  void removeCache(Uri uri) {
    var cache = _cache[uri];
    if (cache != null) {
      size -= cache.size;
    }
    _cache.remove(uri);
  }

  void clear() {
    _cache.clear();
    size = 0;
  }
}

/// Cache data is shared; validation belongs to the client handling this request.
class NetworkCacheInterceptor extends Interceptor {
  NetworkCacheInterceptor(this._client) : _cache = NetworkCacheManager();

  final Dio _client;
  final NetworkCacheManager _cache;
  final _originalHeaders = Expando<Map<String, dynamic>>();

  /// Capture headers before cookie/authentication interceptors mutate them.
  /// Replaying a HEAD through the same pipeline must not append cookies twice.
  late final Interceptor captureRequests = InterceptorsWrapper(
    onRequest: (options, handler) {
      _originalHeaders[options] = Map.from(options.headers);
      handler.next(options);
    },
  );

  void _removeIfCurrent(NetworkCache cache) {
    if (identical(_cache.getCache(cache.uri), cache)) {
      _cache.removeCache(cache.uri);
    }
  }

  void _resolve(
    RequestOptions options,
    NetworkCache cache,
    RequestInterceptorHandler handler,
  ) => handler.resolve(
    Response(
      requestOptions: options,
      data: cache.data,
      headers: Headers.fromMap(cache.responseHeaders)
        ..set('venera-cache', 'true'),
      statusCode: 200,
    ),
  );

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.method != 'GET') {
      return handler.next(options);
    }
    final cacheTime = options.headers.remove('cache-time');
    // URL/header caching cannot represent a GET payload, including a stream
    // that a speculative HEAD must never consume.
    if (options.data != null) return handler.next(options);
    final cache = _cache.getCache(options.uri);
    if (cache == null ||
        !compareHeaders(options.headers, cache.requestHeaders) ||
        (cache.responseType != null &&
            cache.responseType != options.responseType)) {
      return handler.next(options);
    }
    if (cacheTime == 'no') {
      _removeIfCurrent(cache);
      return handler.next(options);
    }
    final cancellation = options.cancelToken?.cancelError;
    if (cancellation != null) return handler.reject(cancellation);
    final age = DateTime.now().difference(cache.time);
    if ((cacheTime == 'long' && age < const Duration(hours: 6)) ||
        age < const Duration(seconds: 5)) {
      return _resolve(options, cache, handler);
    }
    if (age < const Duration(hours: 2)) {
      try {
        final head =
            options.copyWith(
                method: 'HEAD',
                headers: Map.from(_originalHeaders[options] ?? options.headers),
                // A validation response must be consumed even for a streaming GET.
                responseType: ResponseType.bytes,
              )
              ..data = null
              ..onReceiveProgress = null
              ..onSendProgress = null;
        head.headers.remove('cache-time');
        final response = await _client.fetch<dynamic>(head);
        final cancellation = options.cancelToken?.cancelError;
        if (cancellation != null) return handler.reject(cancellation);
        if (response.statusCode == 200 &&
            identical(_cache.getCache(cache.uri), cache) &&
            compareHeaders(options.headers, response.requestOptions.headers) &&
            compareHeaders(cache.responseHeaders, response.headers.map)) {
          return _resolve(options, cache, handler);
        }
      } catch (error, stack) {
        _removeIfCurrent(cache);
        final cancellation = options.cancelToken?.cancelError;
        if (cancellation != null) return handler.reject(cancellation);
        // A server can support GET without implementing HEAD.
        final status = error is DioException
            ? error.response?.statusCode
            : null;
        if (status != 405 && status != 501) {
          return handler.reject(
            error is DioException
                ? error.copyWith(requestOptions: options)
                : DioException(
                    requestOptions: options,
                    error: error,
                    stackTrace: stack,
                  ),
            true,
          );
        }
      }
    }
    _removeIfCurrent(cache);
    handler.next(options);
  }

  static bool compareHeaders(Map<String, dynamic> a, Map<String, dynamic> b) {
    a = {for (final entry in a.entries) entry.key.toLowerCase(): entry.value};
    b = {for (final entry in b.entries) entry.key.toLowerCase(): entry.value};
    const shouldIgnore = [
      'cache-time',
      'prevent-parallel',
      'date',
      'x-varnish',
      'cf-ray',
      'connection',
      'vary',
      'content-encoding',
      'report-to',
      'server-timing',
      'set-cookie',
      'cf-cache-status',
      'cf-request-id',
      'cf-ray',
    ];
    for (var key in shouldIgnore) {
      a.remove(key);
      b.remove(key);
    }
    if (a.length != b.length) {
      return false;
    }
    for (var key in a.keys) {
      if (a[key] is List && b[key] is List) {
        if (a[key].length != b[key].length) {
          return false;
        }
        for (var i = 0; i < a[key].length; i++) {
          if (a[key][i] != b[key][i]) {
            return false;
          }
        }
      } else if (a[key] != b[key]) {
        return false;
      }
    }
    return true;
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (response.requestOptions.method != "GET" ||
        response.requestOptions.data != null) {
      return handler.next(response);
    }
    if (response.statusCode != null && response.statusCode! >= 400) {
      return handler.next(response);
    }
    if (isMalformedExpectedJsonResponse(response)) {
      _cache.removeCache(response.requestOptions.uri);
      return handler.next(response);
    }
    var size = _calculateSize(response.data);
    if (size != null && size < 1024 * 1024 && size > 0) {
      var cache = NetworkCache(
        uri: response.requestOptions.uri,
        requestHeaders: response.requestOptions.headers,
        responseHeaders: Map.from(response.headers.map),
        data: response.data,
        time: DateTime.now(),
        size: size,
        responseType: response.requestOptions.responseType,
      );
      _cache.setCache(cache);
    }
    handler.next(response);
  }

  static int? _calculateSize(Object? data) {
    if (data == null) {
      return 0;
    }
    if (data is List<int>) {
      return data.length;
    }
    if (data is Uint8List) {
      return data.length;
    }
    if (data is String) {
      if (data.trim().isEmpty) {
        return 0;
      }
      if (data.length < 512 && data.contains("IP address")) {
        return 0;
      }
      return data.length * 4;
    }
    if (data is Map) {
      return data.toString().length * 4;
    }
    return null;
  }
}
