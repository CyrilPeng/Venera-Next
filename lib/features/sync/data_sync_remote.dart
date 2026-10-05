import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera_next/network/app_dio.dart' show RHttpAdapter;
import 'package:venera_next/network/webdav.dart';

import 'data_sync_remote_port.dart';

class WebDavDataSyncRemote implements DataSyncRemote {
  WebDavDataSyncRemote(
    WebDavEndpoint connection, {
    Client Function(WebDavEndpoint)? createClient,
  }) : _connection = connection,
       _client = createClient == null
           ? connection.createClient(logRequests: true)
           : createClient(connection) {
    _client.c.interceptors.add(_ListingRedirectGuard());
  }

  final WebDavEndpoint _connection;
  final Client _client;
  Future<void>? _closing;

  @override
  Future<List<String>> listNames() async => [
    for (final entry in await _client.readDir('/'))
      if (entry.name != null) entry.name!,
  ];

  @override
  Future<DataSyncArchiveProbe> probeArchive(String name) => _readArchive(name);

  @override
  Future<DataSyncArchiveCreateResult> createArchiveIfAbsent(
    String name,
    File source, {
    required String sha256,
    required int length,
  }) async {
    _checkOpen();
    _uri(name);
    if (length < 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw ArgumentError('Invalid archive content evidence');
    }
    // Keep an immutable, verified request body for Basic/Digest challenge
    // retries. A consumed file stream cannot safely be submitted a second time.
    final bytes = await source.readAsBytes();
    if (bytes.length != length ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw StateError('Upload archive no longer matches its durable evidence');
    }
    final response = await _request(
      'PUT',
      name,
      data: bytes,
      headers: {
        HttpHeaders.ifNoneMatchHeader: '*',
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
        HttpHeaders.contentLengthHeader: length,
      },
    );
    await _discard(response);
    return switch (response.statusCode) {
      200 || 201 || 204 => DataSyncArchiveCreateResult.created,
      412 => DataSyncArchiveCreateResult.preconditionFailed,
      _ => throw _statusError(response),
    };
  }

  @override
  Future<DataSyncArchiveRemoveResult> removeArchiveIfUnchanged(
    String name, {
    required String strongEtag,
  }) async {
    _checkOpen();
    if (!_isStrongEtag(strongEtag)) {
      throw ArgumentError.value(
        strongEtag,
        'strongEtag',
        'A strong entity tag is required',
      );
    }
    final response = await _request(
      'DELETE',
      name,
      headers: {HttpHeaders.ifMatchHeader: strongEtag},
    );
    await _discard(response);
    return switch (response.statusCode) {
      200 || 204 => DataSyncArchiveRemoveResult.removed,
      404 => DataSyncArchiveRemoveResult.missing,
      412 => DataSyncArchiveRemoveResult.preconditionFailed,
      _ => throw _statusError(response),
    };
  }

  @override
  Future<void> readToFile(String name, String path) async {
    await _readArchive(name, destination: File(path));
  }

  Future<DataSyncArchiveProbe> _readArchive(
    String name, {
    File? destination,
  }) async {
    final response = await _request('GET', name);
    if (response.statusCode != HttpStatus.ok) {
      await _discard(response);
      if (response.statusCode == HttpStatus.notFound && destination == null) {
        return const DataSyncArchiveMissing();
      }
      throw _statusError(response);
    }
    final encoding = response.headers.map[HttpHeaders.contentEncodingHeader];
    if (encoding != null &&
        (encoding.length != 1 || encoding.single.toLowerCase() != 'identity')) {
      await _discard(response);
      throw const FormatException(
        'Archive response ignored identity content encoding',
      );
    }
    final lengths = response.headers.map[HttpHeaders.contentLengthHeader];
    final expectedLength = lengths?.length == 1
        ? int.tryParse(lengths!.single)
        : null;
    if (lengths != null && (expectedLength == null || expectedLength < 0)) {
      await _discard(response);
      throw const FormatException('Invalid archive Content-Length');
    }
    final body = response.data!;
    RandomAccessFile? output;
    var length = 0;
    var subscribed = false;
    var completed = false;
    try {
      if (destination != null) {
        await destination.parent.create(recursive: true);
        output = await destination.open(mode: FileMode.write);
      }
      Stream<List<int>> chunks() async* {
        subscribed = true;
        await for (final chunk in body.stream) {
          length += chunk.length;
          if (expectedLength != null && length > expectedLength) {
            throw const FormatException('Archive body exceeds Content-Length');
          }
          await output?.writeFrom(chunk);
          yield chunk;
        }
      }

      final digest = await crypto.sha256.bind(chunks()).first;
      await _waitForNativeIdle();
      if (expectedLength != null && length != expectedLength) {
        throw const FormatException(
          'Archive body is shorter than Content-Length',
        );
      }
      await output?.flush();
      final tags = response.headers.map[HttpHeaders.etagHeader];
      final tag = tags?.length == 1 ? tags!.single : null;
      completed = true;
      return DataSyncArchivePresent(
        sha256: digest.toString(),
        length: length,
        strongEtag: tag != null && _isStrongEtag(tag) ? tag : null,
      );
    } finally {
      // Dio does not forward downstream subscription cancellation to the
      // adapter; cancel the request itself if local output cannot be opened.
      if (!completed) response.requestOptions.cancelToken?.cancel();
      if (!subscribed) await body.stream.listen(null).cancel();
      await output?.close();
    }
  }

  Uri _uri(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(name, 'name', 'Expected one archive filename');
    }
    final base = Uri.parse(_connection.url);
    final directory = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(
      path: '$directory${Uri.encodeComponent(name)}',
      fragment: '',
    );
  }

  void _checkOpen() {
    if (_closing != null) {
      throw DioException(
        requestOptions: RequestOptions(path: _connection.url),
        error: StateError('WebDAV remote is closed'),
      );
    }
  }

  Future<Response<ResponseBody>> _request(
    String method,
    String name, {
    Uint8List? data,
    Map<String, Object> headers = const {},
  }) async {
    _checkOpen();
    final uri = _uri(name);
    // WdDio.req follows 301/302 itself even when followRedirects is false.
    // Use its public auth objects with explicit, bounded challenge retries.
    for (var attempt = 0; ; attempt++) {
      _checkOpen();
      final target = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      final auth = _client.auth;
      // SDK DigestAuth normally encodes its argument again. Preserve the exact
      // wire target (including escaped reserved characters and query) while
      // retaining the SDK's algorithm and the client's cached challenge.
      final signer = auth is DigestAuth
          ? DigestAuth(
              user: auth.user,
              pwd: auth.pwd,
              dParts: _WireDigestParts(auth.dParts, target),
            )
          : auth;
      final authorization = signer.authorize(method, target);
      final response = await _client.c.requestUri<ResponseBody>(
        uri,
        data: data,
        cancelToken: CancelToken(),
        options: Options(
          method: method,
          followRedirects: false,
          maxRedirects: 0,
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          headers: {
            HttpHeaders.acceptEncodingHeader: 'identity',
            ...headers,
            HttpHeaders.authorizationHeader: ?authorization,
          },
        ),
      );
      if (response.statusCode != HttpStatus.unauthorized) return response;
      await _discard(response);
      if (attempt >= 2 || !_authenticate(response)) {
        throw _statusError(response);
      }
    }
  }

  bool _authenticate(Response<ResponseBody> response) {
    final challenges =
        response.headers.map[HttpHeaders.wwwAuthenticateHeader] ?? const [];
    String? challenge(String scheme) {
      for (final value in challenges) {
        if (value.toLowerCase().startsWith('$scheme ')) return value;
      }
      return null;
    }

    final auth = _client.auth;
    final digest = challenge('digest');
    if (digest != null &&
        (auth.type == AuthType.NoAuth ||
            auth.type == AuthType.DigestAuth &&
                RegExp(
                  r'stale\s*=\s*true',
                  caseSensitive: false,
                ).hasMatch(digest))) {
      _client.auth = DigestAuth(
        user: auth.user,
        pwd: auth.pwd,
        dParts: DigestParts(digest),
      );
      return true;
    }
    if (auth.type == AuthType.NoAuth && challenge('basic') != null) {
      _client.auth = BasicAuth(user: auth.user, pwd: auth.pwd);
      return true;
    }
    return false;
  }

  Future<void> _discard(Response<ResponseBody> response) async {
    var length = 0;
    await for (final chunk in response.data!.stream) {
      length += chunk.length;
    }
    await _waitForNativeIdle();
    final lengths = response.headers.map[HttpHeaders.contentLengthHeader];
    if (lengths != null &&
        (lengths.length != 1 || int.tryParse(lengths.single) != length)) {
      throw const FormatException('Incomplete WebDAV response body');
    }
  }

  Future<void> _waitForNativeIdle() async {
    final adapter = _client.c.httpClientAdapter;
    if (adapter is RHttpAdapter) await adapter.waitForIdle();
  }

  DioException _statusError(Response<ResponseBody> response) =>
      DioException.badResponse(
        statusCode: response.statusCode ?? 0,
        requestOptions: response.requestOptions,
        response: response,
      );

  @override
  Future<void> dispose() => _closing ??= closeWebDavClient(_client);
}

bool _isStrongEtag(String value) =>
    RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);

class _WireDigestParts extends DigestParts {
  _WireDigestParts(DigestParts source, this.target) : super(null) {
    parts.addAll(source.parts);
  }

  final String target;

  @override
  String get uri => target;
  @override
  set uri(String value) {}
}

/// Keep SDK listing/XML and authentication, but prevent its explicit 301/302
/// retry as well as automatic transport redirects from changing the endpoint.
class _ListingRedirectGuard extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.method == 'PROPFIND') {
      options.followRedirects = false;
      options.maxRedirects = 0;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final status = response.statusCode;
    if (response.requestOptions.method == 'PROPFIND' &&
        status != null &&
        status >= 300 &&
        status < 400) {
      handler.reject(
        DioException.badResponse(
          statusCode: status,
          requestOptions: response.requestOptions,
          response: response,
        ),
      );
      return;
    }
    handler.next(response);
  }
}
