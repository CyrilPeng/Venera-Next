import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/features/webdav_library/webdav_library_config.dart';
import 'package:venera_next/features/webdav_library/webdav_library_transport.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/app_dio.dart' show RHttpAdapter;
import 'package:venera_next/network/rhttp_stream_request.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;
import 'package:xml/xml.dart';

const _emptyDirectory =
    '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>';

WebDavLibraryConfig _config(String url, {String user = ''}) =>
    WebDavLibraryConfig(
      url: url,
      user: user,
      pass: '',
      remotePath: '/library/',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    App.version = 'transport-test';
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });

  test(
    'dispose attempts every SDK client and permanently rejects new work',
    () async {
      final adapters = <_CloseAdapter>[];
      final ops = WebDavHttpLibraryOps(
        createClient: (config) {
          final adapter = _CloseAdapter(failClose: true);
          adapters.add(adapter);
          return webdav.newClient(config.url, adapter: adapter);
        },
      );
      final config = _config('https://transport.example.test');
      await ops.test(config);
      await ops.test(_config(config.url, user: 'other'));
      expect(adapters, hasLength(2));
      expect(
        ops.dispose,
        throwsA(
          isA<WebDavTransportCloseFailure>().having(
            (error) => error.failures.length,
            'all client failures',
            2,
          ),
        ),
      );
      expect(adapters.map((adapter) => adapter.closes), [1, 1]);
      ops.dispose();
      expect(adapters.map((adapter) => adapter.closes), [1, 1]);
      await expectLater(ops.test(config), throwsStateError);
      await expectLater(ops.readDir(config, '/library/'), throwsStateError);
      await expectLater(
        ops.readText(config, '/metadata.json'),
        throwsStateError,
      );
      expect(adapters, hasLength(2));
    },
  );

  for (final partialResponse in [false, true]) {
    test(
      'native SDK cancellation and resume; partial response=$partialResponse',
      () async {
        App.version = 'transport-test';
        final previousProxy = appdata.settings['proxy'];
        appdata.settings['proxy'] = 'direct';
        final server = await _HoldingServer.start();
        server.partialResponse = partialResponse;
        final ops = WebDavHttpLibraryOps();
        addTearDown(() async {
          ops.dispose();
          await ops.drainPending();
          await server.close();
          appdata.settings['proxy'] = previousProxy;
        });
        final requests = StreamIterator(server.requests.stream);
        addTearDown(requests.cancel);
        final config = _config(server.url);
        final checking = ops.test(config);
        final listing = ops.readDir(config, '/library/book/');
        final reading = ops.readText(config, '/library/metadata.json');
        final cancelled = Future.wait([
          expectLater(
            checking,
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                'type',
                DioExceptionType.cancel,
              ),
            ),
          ),
          expectLater(
            listing,
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                'type',
                DioExceptionType.cancel,
              ),
            ),
          ),
          expectLater(
            reading,
            throwsA(
              isA<DioException>().having(
                (error) => error.type,
                'type',
                DioExceptionType.cancel,
              ),
            ),
          ),
        ]);
        final active = <_HeldRequest>[];
        for (var i = 0; i < 3; i++) {
          expect(
            await requests.moveNext().timeout(const Duration(seconds: 10)),
            isTrue,
          );
          active.add(requests.current);
        }
        expect(
          active.map((request) => request.method),
          unorderedEquals(['PROPFIND', 'PROPFIND', 'GET']),
        );
        ops.cancelPending();
        await cancelled;
        await ops.drainPending();
        // Verify the cancellation reaches Rhttp and the peer, not just Dio's
        // early cancellation result. This uses no external network service.
        await Future.wait(
          active.map((request) => request.closed),
        ).timeout(const Duration(seconds: 10));

        server.respond = true;
        expect(await ops.readDir(config, '/library/'), isEmpty);
        expect(await ops.readText(config, '/library/metadata.json'), '{}');

        server.respond = false;
        final finalRequest = ops.test(config);
        final finalResult = expectLater(
          finalRequest,
          throwsA(isA<DioException>()),
        );
        expect(
          await requests.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        final accepted = requests.current;
        ops.dispose();
        await finalResult;
        await ops.drainPending();
        await accepted.closed.timeout(const Duration(seconds: 10));
        await expectLater(ops.test(config), throwsStateError);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'settings cancellation drains preparation without native dispatch',
    () async {
      var nativeDispatches = 0;
      final adapter = _DelayedSettingsAdapter(
        start: (options, settings, upload) async {
          nativeDispatches++;
          throw StateError('cancelled preparation must not dispatch');
        },
      );
      final ops = WebDavHttpLibraryOps(
        createClient: (config) =>
            webdav.newClient(config.url, adapter: adapter),
      );
      addTearDown(() async {
        if (!adapter.release.isCompleted) adapter.release.complete();
        ops.dispose();
        await ops.drainPending();
      });
      final pending = ops.test(_config('http://127.0.0.1:1'));
      final cancelled = expectLater(pending, throwsA(isA<DioException>()));
      await adapter.entered.future.timeout(const Duration(seconds: 10));
      ops.cancelPending();
      await cancelled.timeout(const Duration(seconds: 10));
      var drained = false;
      final drain = ops.drainPending().then((_) => drained = true);
      await pumpEventQueue();
      expect(drained, isFalse);
      expect(nativeDispatches, 0);
      adapter.release.complete();
      await drain.timeout(const Duration(seconds: 10));
      expect(drained, isTrue);
      expect(nativeDispatches, 0);
    },
  );

  test(
    'native SDK PROPFIND sends finite XML and preserves Chinese properties',
    () async {
      final server = await _ContentServer.start();
      final adapter = _TestAdapter();
      final ops = WebDavHttpLibraryOps(
        createClient: (config) =>
            webdav.newClient(config.url, adapter: adapter),
      );
      addTearDown(() async {
        ops.dispose();
        await ops.drainPending();
        await server.close();
      });

      final entries = await ops
          .readDir(_config(server.url), '/library/')
          .timeout(const Duration(seconds: 10));
      expect(entries, hasLength(2));
      expect(entries[0].name, '中文目录');
      expect(entries[0].isDirectory, isTrue);
      expect(entries[0].eTag, '"目录版本一"');
      expect(
        entries[0].modifiedAt,
        DateTime.utc(2026, 10, 4, 1, 2, 3).millisecondsSinceEpoch,
      );
      expect(entries[1].name, 'metadata.json');
      expect(entries[1].isDirectory, isFalse);
      expect(entries[1].eTag, '"metadata-v1"');
      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.method, 'PROPFIND');
      expect(request.path, '/library/');
      expect(request.depth, '1');
      expect(request.contentType, contains('application/xml'));
      expect(request.body, isNotEmpty);
      expect(request.body.length, lessThan(4096));
      final xml = XmlDocument.parse(utf8.decode(request.body));
      expect(xml.rootElement.name.local, 'propfind');
      expect(xml.rootElement.namespaceUri, 'DAV:');
      expect(
        xml
            .findAllElements('prop', namespace: 'DAV:')
            .single
            .childElements
            .map((property) => property.name.local),
        containsAll(['resourcetype', 'getetag', 'getlastmodified']),
      );
      await ops.drainPending().timeout(const Duration(seconds: 10));
    },
    skip: !Platform.isWindows,
  );

  test(
    'native SDK GET joins chunked metadata across UTF-8 byte boundaries',
    () async {
      final server = await _ContentServer.start();
      final ops = WebDavHttpLibraryOps(
        createClient: (config) =>
            webdav.newClient(config.url, adapter: _TestAdapter()),
      );
      addTearDown(() async {
        ops.dispose();
        await ops.drainPending();
        await server.close();
      });
      final text = await ops
          .readText(_config(server.url), '/library/中文目录/metadata.json')
          .timeout(const Duration(seconds: 10));
      expect(text, _metadata);
      expect((jsonDecode(text) as Map)['title'], '中文目录 📚');
      expect(server.requests.map((request) => request.method), [
        'OPTIONS',
        'GET',
      ]);
      final get = server.requests.last;
      expect(Uri.decodeFull(get.path), '/library/中文目录/metadata.json');
      expect(get.body, isEmpty);
      expect(server.splitUtf8Responses, 1);
      await ops.drainPending().timeout(const Duration(seconds: 10));
    },
    skip: !Platform.isWindows,
  );

  for (final method in ['PROPFIND', 'GET']) {
    test(
      'native SDK $method HTTP error stays on request and drains normally',
      () async {
        final server = await _ContentServer.start(failMethod: method);
        final ops = WebDavHttpLibraryOps(
          createClient: (config) =>
              webdav.newClient(config.url, adapter: _TestAdapter()),
        );
        addTearDown(() async {
          ops.dispose();
          await ops.drainPending();
          await server.close();
        });
        final config = _config(server.url);
        final request = method == 'PROPFIND'
            ? ops.readDir(config, '/library/')
            : ops.readText(config, '/library/metadata.json');
        await expectLater(
          request.timeout(const Duration(seconds: 10)),
          throwsA(
            isA<DioException>().having(
              (error) => error.response?.statusCode,
              'HTTP status',
              HttpStatus.forbidden,
            ),
          ),
        );
        await ops.drainPending().timeout(const Duration(seconds: 10));
        await ops.drainPending();
        ops.dispose();
        await ops.drainPending();
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'all client gates finish before aggregate cleanup failure remains on drain',
    () async {
      final firstCancelError = StateError('first native cancel failed');
      final firstFinishError = StateError('first native release failed');
      final secondFinishError = StateError('second native release failed');
      final cancelStack = StackTrace.fromString('first cancellation stack');
      final firstStack = StackTrace.fromString('first native release stack');
      final secondStack = StackTrace.fromString('second native release stack');
      final first = _ControlledCall(
        cancelError: firstCancelError,
        cancelStack: cancelStack,
      );
      final second = _ControlledCall();
      final created = <String>[];
      final ops = WebDavHttpLibraryOps(
        createClient: (config) {
          created.add(config.connectionKey);
          return webdav.newClient(
            config.url,
            adapter: _TestAdapter(
              start: config.user == 'first' ? first.start : second.start,
            ),
          );
        },
      );
      addTearDown(() async {
        ops.dispose();
        first.release();
        second.release();
        try {
          await ops.drainPending();
        } on WebDavTransportCloseFailure {
          // These controlled calls deliberately fail cleanup.
        }
      });
      final firstConfig = _config('http://127.0.0.1:1', user: 'first');
      final secondConfig = _config(firstConfig.url, user: 'second');
      final firstResult = expectLater(
        ops.test(firstConfig),
        throwsA(isA<DioException>()),
      );
      final secondResult = expectLater(
        ops.test(secondConfig),
        throwsA(isA<DioException>()),
      );
      await Future.wait([first.started.future, second.started.future]);
      expect(created, [firstConfig.connectionKey, secondConfig.connectionKey]);
      ops.dispose();
      await Future.wait([firstResult, secondResult]);
      await Future.wait([first.cancelled.future, second.cancelled.future]);
      first.headers.completeError(StateError('first request cancelled'));
      second.headers.completeError(StateError('second request cancelled'));
      await Future.wait([first.body.close(), second.body.close()]);
      first.finished.completeError(firstFinishError, firstStack);

      var drainSettled = false;
      final drain = ops
          .drainPending()
          .then<WebDavTransportCloseFailure>(
            (_) => throw StateError('cleanup must fail'),
            onError: (Object error, StackTrace stack) =>
                error as WebDavTransportCloseFailure,
          )
          .whenComplete(() => drainSettled = true);
      await pumpEventQueue();
      expect(drainSettled, isFalse);
      second.finished.completeError(secondFinishError, secondStack);
      final failure = await drain.timeout(const Duration(seconds: 10));
      expect(failure.failures, hasLength(2));
      expect(
        failure.failures.map((failure) => failure.error),
        everyElement(isA<RHttpCleanupFailure>()),
      );
      final originalFailures = failure.failures
          .expand((failure) => (failure.error as RHttpCleanupFailure).failures)
          .toList();
      expect(originalFailures, hasLength(3));
      for (final expected in [
        (error: firstCancelError, stack: cancelStack),
        (error: firstFinishError, stack: firstStack),
        (error: secondFinishError, stack: secondStack),
      ]) {
        final retained = originalFailures.singleWhere(
          (failure) => identical(failure.error, expected.error),
        );
        expect(retained.stack.toString(), expected.stack.toString());
      }
      expect(
        failure.failures.map((failure) => failure.stack.toString()),
        everyElement(isNotEmpty),
      );
      await expectLater(
        ops.drainPending(),
        throwsA(
          isA<WebDavTransportCloseFailure>().having(
            (error) => error.failures
                .expand(
                  (failure) => (failure.error as RHttpCleanupFailure).failures,
                )
                .map((failure) => failure.error),
            'retained original errors',
            unorderedEquals([
              same(firstCancelError),
              same(firstFinishError),
              same(secondFinishError),
            ]),
          ),
        ),
      );
      await expectLater(ops.test(firstConfig), throwsStateError);
    },
  );

  test(
    'successful active drain retains all adapters until disposed and drained',
    () async {
      final firstCalls = <_ControlledCall>[];
      final secondCalls = <_ControlledCall>[];
      final ops = WebDavHttpLibraryOps(
        createClient: (config) => webdav.newClient(
          config.url,
          adapter: _TestAdapter(
            start: (options, settings, upload) {
              final call = _ControlledCall();
              (config.user == 'first' ? firstCalls : secondCalls).add(call);
              return call.start(options, settings, upload);
            },
          ),
        ),
      );
      addTearDown(() async {
        ops.dispose();
        for (final call in [...firstCalls, ...secondCalls]) {
          call.release();
        }
        await ops.drainPending();
      });
      final configs = [
        _config('http://127.0.0.1:1', user: 'first'),
        _config('http://127.0.0.1:1', user: 'second'),
      ];
      final completed = Future.wait(configs.map(ops.test));
      await pumpEventQueue();
      expect(firstCalls, hasLength(1));
      expect(secondCalls, hasLength(1));
      for (final call in [firstCalls.single, secondCalls.single]) {
        await call.succeed();
      }
      await completed;
      await ops.drainPending();

      // A successful drain while open must keep tracking both cached clients.
      final cancelled = Future.wait(
        configs.map(
          (config) =>
              expectLater(ops.test(config), throwsA(isA<DioException>())),
        ),
      );
      await pumpEventQueue();
      expect(firstCalls, hasLength(2));
      expect(secondCalls, hasLength(2));
      ops.dispose();
      await cancelled;
      final active = [firstCalls.last, secondCalls.last];
      for (final call in active) {
        call.headers.completeError(StateError('request cancelled'));
        await call.body.close();
      }
      var drained = false;
      final drain = ops.drainPending().then((_) => drained = true);
      active.first.finished.complete();
      await pumpEventQueue();
      expect(drained, isFalse);
      active.last.finished.complete();
      await drain.timeout(const Duration(seconds: 10));
      expect(drained, isTrue);
      await ops.drainPending();
      await expectLater(ops.test(configs.first), throwsStateError);
    },
  );
}

class _DelayedSettingsAdapter extends RHttpAdapter {
  _DelayedSettingsAdapter({required RHttpStreamCallFactory start})
    : super(startStreamCall: start);
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<rhttp.ClientSettings> get settings async {
    entered.complete();
    await release.future;
    return const rhttp.ClientSettings(
      proxySettings: rhttp.ProxySettings.noProxy(),
      throwOnStatusCode: false,
    );
  }
}

class _TestAdapter extends RHttpAdapter {
  _TestAdapter({RHttpStreamCallFactory? start}) : super(startStreamCall: start);

  @override
  Future<rhttp.ClientSettings> get settings async => const rhttp.ClientSettings(
    proxySettings: rhttp.ProxySettings.noProxy(),
    throwOnStatusCode: false,
  );
}

class _ControlledCall {
  _ControlledCall({this.cancelError, this.cancelStack});

  final Object? cancelError;
  final StackTrace? cancelStack;
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  final headers =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();

  Future<RHttpStreamCall> start(
    RequestOptions options,
    rhttp.ClientSettings settings,
    Stream<Uint8List>? upload,
  ) async {
    // The WebDAV SDK supplies a finite PROPFIND XML body. Consume it just as
    // a native call would; this fixture controls native exit, not an SDK upload.
    if (upload != null) await upload.drain<void>();
    started.complete();
    return RHttpStreamCall(
      response: headers.future,
      body: body.stream,
      finished: finished.future,
      cancel: () async {
        if (!cancelled.isCompleted) cancelled.complete();
        if (cancelError != null) {
          Error.throwWithStackTrace(cancelError!, cancelStack!);
        }
      },
    );
  }

  Future<void> succeed() async {
    headers.complete((
      statusCode: HttpStatus.multiStatus,
      headers: <String, List<String>>{},
    ));
    body.add(Uint8List.fromList(utf8.encode(_emptyDirectory)));
    await body.close();
    finished.complete();
  }

  void release() {
    if (!headers.isCompleted) {
      headers.completeError(StateError('fixture disposed'));
    }
    if (!finished.isCompleted) finished.complete();
    unawaited(body.close());
  }
}

const _metadata = '{"title":"中文目录 📚","description":"分块 UTF-8 数据"}';
const _directoryProperties = '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/library/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/library/%E4%B8%AD%E6%96%87%E7%9B%AE%E5%BD%95/</d:href>
    <d:propstat><d:prop><d:displayname>中文目录</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getetag>&quot;目录版本一&quot;</d:getetag>
      <d:getlastmodified>Sun, 04 Oct 2026 01:02:03 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response><d:href>/library/metadata.json</d:href><d:propstat><d:prop>
    <d:resourcetype/><d:getcontentlength>64</d:getcontentlength>
    <d:getetag>&quot;metadata-v1&quot;</d:getetag>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''';

class _ReceivedRequest {
  _ReceivedRequest(HttpRequest request, this.body)
    : method = request.method,
      path = request.uri.path,
      depth = request.headers.value('depth'),
      contentType = request.headers.value(HttpHeaders.contentTypeHeader);

  final String method;
  final String path;
  final String? depth;
  final String? contentType;
  final List<int> body;
}

class _ContentServer {
  _ContentServer(this.server, this.failMethod) {
    server.listen(_handle);
  }

  final HttpServer server;
  final String? failMethod;
  final requests = <_ReceivedRequest>[];
  int splitUtf8Responses = 0;
  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_ContentServer> start({String? failMethod}) async =>
      _ContentServer(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        failMethod,
      );

  Future<void> _handle(HttpRequest request) async {
    final body = await request.expand((chunk) => chunk).toList();
    requests.add(_ReceivedRequest(request, body));
    final response = request.response;
    if (request.method == failMethod) {
      response.statusCode = HttpStatus.forbidden;
      response.write('access denied');
    } else if (request.method != 'OPTIONS') {
      response.statusCode = request.method == 'PROPFIND'
          ? HttpStatus.multiStatus
          : HttpStatus.ok;
      response.headers.contentType = ContentType(
        'application',
        request.method == 'PROPFIND' ? 'xml' : 'json',
        charset: 'utf-8',
      );
      // HTTP chunked transfer deliberately cuts inside a multibyte character.
      final bytes = utf8.encode(
        request.method == 'PROPFIND' ? _directoryProperties : _metadata,
      );
      final split = bytes.indexWhere((byte) => byte >= 0xc0) + 1;
      response.bufferOutput = false;
      response.add(bytes.sublist(0, split));
      await response.flush();
      response.add(bytes.sublist(split, split + 1));
      await response.flush();
      response.add(bytes.sublist(split + 1));
      splitUtf8Responses++;
    }
    await response.close();
  }

  Future<void> close() async => server.close(force: true);
}

class _CloseAdapter implements HttpClientAdapter {
  _CloseAdapter({required this.failClose});
  final bool failClose;
  int closes = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(_emptyDirectory, 207);

  @override
  void close({bool force = false}) {
    closes++;
    if (failClose) throw StateError('client close failed');
  }
}

class _HeldRequest {
  _HeldRequest(this.method, this.closed);
  final String method;
  final Future<void> closed;
}

class _HoldingServer {
  _HoldingServer(this.server) {
    server.listen(_accept);
  }
  final ServerSocket server;
  final sockets = <Socket>{};
  final requests = StreamController<_HeldRequest>();
  bool respond = false;
  bool partialResponse = false;
  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_HoldingServer> start() async =>
      _HoldingServer(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  void _accept(Socket socket) {
    sockets.add(socket);
    final closed = Completer<void>();
    var firstLine = '';
    var handled = false;
    socket.listen(
      (bytes) {
        if (handled) return;
        firstLine += ascii.decode(bytes, allowInvalid: true);
        if (!firstLine.contains('\r\n')) return;
        handled = true;
        final method = firstLine.split(' ').first;
        if (method == 'OPTIONS' || respond) {
          final body = method == 'OPTIONS'
              ? ''
              : (method == 'GET' ? '{}' : _emptyDirectory);
          final status = method == 'PROPFIND' ? '207 Multi-Status' : '200 OK';
          socket.write(
            'HTTP/1.1 $status\r\nContent-Length: ${utf8.encode(body).length}\r\nConnection: close\r\n\r\n$body',
          );
          unawaited(socket.flush().then((_) => socket.close()));
        } else {
          if (partialResponse) {
            socket.write('HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\nx');
            unawaited(socket.flush());
          }
          requests.add(_HeldRequest(method, closed.future));
        }
      },
      onDone: () {
        sockets.remove(socket);
        socket.destroy();
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        sockets.remove(socket);
        socket.destroy();
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await server.close();
    await requests.close();
  }
}
