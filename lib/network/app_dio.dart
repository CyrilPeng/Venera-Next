import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error("Network",
        "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}");
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
              message: "Invalid Status Code: $statusCode. "
                  "${_getStatusCodeInfo(statusCode)}");
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
            message: "Receive Timeout: "
                "This indicates that the server is too busy to respond");
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
              message: "Connection terminated during handshake: "
                  "This may be caused by the firewall blocking the connection "
                  "or your requests are too frequent.");
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
              message: "Connection reset by peer: "
                  "The error is unrelated to app, please check your network.");
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    var headers = response.headers.map.map((key, value) => MapEntry(
        key.toLowerCase(), value.length == 1 ? value.first : value.toString()));
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
        (response.statusCode != null && response.statusCode! < 400)
            ? LogLevel.info
            : LogLevel.error,
        "Network",
        "Response ${response.realUri.toString()} ${response.statusCode}\n"
            "headers:\n$headers\n$content");
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    Log.info(
        "Network",
        "${options.method} ${options.uri}\n"
            "headers:\n${
              options.extra.containsKey("maskHeadersInLog")
                ? options.headers.map((key, value) =>
                  MapEntry(
                    key,
                    options.extra["maskHeadersInLog"].contains(key)
                      ? headerMask
                      : value
                  ))
                : options.headers
            }\n"
            "data:\n${
              options.extra["maskDataInLog"] == true
                ? dataMask
                : options.data
            }"
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = AppHttpClientAdapter();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, Future<void>> _requestTails = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    Completer<void>? requestCompleter;
    if (options?.headers?['prevent-parallel'] == 'true') {
      final previousRequest = _requestTails[path];
      requestCompleter = Completer<void>();
      _requestTails[path] = requestCompleter.future;
      options!.headers!.remove('prevent-parallel');
      if (previousRequest != null) {
        await previousRequest;
      }
    }
    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (requestCompleter != null) {
        if (identical(_requestTails[path], requestCompleter.future)) {
          _requestTails.remove(path);
        }
        requestCompleter.complete();
      }
    }
  }
}

class AppHttpClientAdapter implements HttpClientAdapter {
  IOHttpClientAdapter? _adapter;
  String? _proxy;
  bool? _ignoreBadCertificate;
  bool? _enableDnsOverrides;
  bool? _sni;
  Map<String, String> _dnsOverrides = {};

  @override
  void close({bool force = false}) {
    _adapter?.close(force: force);
    _adapter = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    await _refreshSettings();
    return _adapter!.fetch(options, requestStream, cancelFuture);
  }

  Future<void> _refreshSettings() async {
    var proxy = await getProxy();
    var ignoreBadCertificate =
        appdata.settings['ignoreBadCertificate'] == true;
    var enableDnsOverrides = appdata.settings['enableDnsOverrides'] == true;
    var sni = appdata.settings['sni'] != false;
    var dnsOverrides = _getDnsOverrides();
    if (_adapter == null ||
        _ignoreBadCertificate != ignoreBadCertificate ||
        _enableDnsOverrides != enableDnsOverrides ||
        _sni != sni ||
        !_mapEquals(_dnsOverrides, dnsOverrides)) {
      _adapter?.close(force: true);
      _proxy = proxy;
      _ignoreBadCertificate = ignoreBadCertificate;
      _enableDnsOverrides = enableDnsOverrides;
      _sni = sni;
      _dnsOverrides = dnsOverrides;
      _adapter = _createAdapter();
    } else {
      _proxy = proxy;
    }
  }

  IOHttpClientAdapter _createAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient()
          ..idleTimeout = const Duration(seconds: 60)
          ..findProxy = (uri) => _proxy == null ? "DIRECT" : "PROXY $_proxy";
        if (_ignoreBadCertificate == true) {
          client.badCertificateCallback = (cert, host, port) => true;
        }
        if (_enableDnsOverrides == true || _sni == false) {
          client.connectionFactory = _connectionFactory;
        }
        return client;
      },
    );
  }

  Future<ConnectionTask<Socket>> _connectionFactory(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    final host = proxyHost ?? _dnsOverrides[uri.host] ?? uri.host;
    final port = proxyPort ?? uri.port;
    final connectTask = await Socket.startConnect(host, port);
    if (uri.scheme != 'https' || proxyHost != null) {
      return connectTask;
    }

    final socket = connectTask.socket.then((socket) {
      return SecureSocket.secure(
        socket,
        host: _sni == false ? null : uri.host,
        onBadCertificate:
            _ignoreBadCertificate == true ? (certificate) => true : null,
      );
    });
    return ConnectionTask.fromSocket(socket, connectTask.cancel);
  }

  static Map<String, String> _getDnsOverrides() {
    var config = appdata.settings['dnsOverrides'];
    var result = <String, String>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = entry.value;
        }
      }
    }
    return result;
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var entry in a.entries) {
      if (b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
