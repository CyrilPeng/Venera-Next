import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/cache.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/network/owned_dio_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });
  const url = 'http://127.0.0.1:1/cache-owner';
  final cache = NetworkCacheManager();

  setUp(() {
    final initialized = App.isInitialized;
    final muted = Log.isMuted;
    App.isInitialized = true;
    Log.isMuted = true;
    cache.clear();
    addTearDown(() {
      App.isInitialized = initialized;
      Log.isMuted = muted;
      cache.clear();
    });
  });

  void seed({
    Duration age = const Duration(minutes: 1),
    Map<String, dynamic> headers = const {},
    ResponseType? responseType,
    Object data = 'cached',
  }) => cache.setCache(
    NetworkCache(
      uri: Uri.parse(url),
      requestHeaders: headers,
      responseHeaders: const {},
      data: data,
      time: DateTime.now().subtract(age),
      size: 6,
      responseType: responseType,
    ),
  );

  test('revalidation uses the original client adapter', () async {
    seed();
    final adapter = _Adapter((_) async => ResponseBody.fromString('', 200));
    final dio = AppDio()..httpClientAdapter = adapter;
    final token = CancelToken();
    final outcome = dio
        .get<String>(url, cancelToken: token)
        .then<Object>((value) => value, onError: (Object error) => error);
    try {
      final result = await outcome.timeout(const Duration(seconds: 3));
      expect(adapter.methods, ['HEAD']);
      expect(result, isA<Response<String>>());
      expect((result as Response<String>).data, 'cached');
      expect(adapter.closes, 0);
    } finally {
      token.cancel();
      dio.close(force: true);
    }
  });

  test('authorization changes cannot reuse another credential cache', () async {
    seed(age: Duration.zero, headers: {'authorization': 'Bearer first'});
    final adapter = _Adapter(
      (_) async => ResponseBody.fromString('current account', 200),
    );
    final dio = AppDio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final response = await dio.get<String>(
      url,
      options: Options(headers: {'authorization': 'Bearer second'}),
    );
    expect(response.data, 'current account');
    expect(adapter.methods, ['GET']);
  });

  for (final status in [400, 403, 500]) {
    test(
      'HEAD failure $status completes the original GET with its cause',
      () async {
        seed();
        final adapter = _Adapter(
          (_) async => ResponseBody.fromString('', status),
        );
        final dio = AppDio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        await expectLater(
          dio.get<String>(url).timeout(const Duration(seconds: 2)),
          throwsA(
            isA<DioException>()
                .having((e) => e.response?.statusCode, 'status', status)
                .having(
                  (e) => e.requestOptions.method,
                  'original method',
                  'GET',
                ),
          ),
        );
        expect(adapter.methods, ['HEAD']);
        expect(cache.getCache(Uri.parse(url)), isNull);
      },
    );
  }

  for (final status in [405, 501]) {
    test('unsupported HEAD $status falls through to one GET', () async {
      seed();
      final adapter = _Adapter(
        (options) async => ResponseBody.fromString(
          options.method == 'GET' ? 'fresh' : '',
          options.method == 'GET' ? 200 : status,
        ),
      );
      final dio = AppDio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      expect((await dio.get<String>(url)).data, 'fresh');
      expect(adapter.methods, ['HEAD', 'GET']);
    });
  }

  test('transport error preserves the original object and stack', () async {
    seed();
    final cause = StateError('HEAD transport');
    final stack = StackTrace.current;
    final adapter = _Adapter(
      (options) => Future.error(
        DioException(requestOptions: options, error: cause, stackTrace: stack),
        stack,
      ),
    );
    final dio = AppDio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    await expectLater(
      dio.get<String>(url),
      throwsA(
        isA<DioException>()
            .having((e) => e.error, 'original error', same(cause))
            .having((e) => e.stackTrace, 'original stack', same(stack)),
      ),
    );
  });

  test('clearing cache during validation cannot return its old body', () async {
    seed();
    final entered = Completer<void>();
    final head = Completer<ResponseBody>();
    final adapter = _Adapter((options) async {
      if (options.method == 'HEAD') {
        entered.complete();
        return head.future;
      }
      return ResponseBody.fromString('fresh', 200);
    });
    final dio = AppDio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final request = dio.get<String>(url);
    await entered.future;
    cache.clear();
    head.complete(ResponseBody.fromString('', 200));
    expect((await request).data, 'fresh');
    expect(adapter.methods, ['HEAD', 'GET']);
  });

  test('failed old validation cannot remove a replacement cache', () async {
    seed();
    final entered = Completer<void>();
    final head = Completer<ResponseBody>();
    final adapter = _Adapter((_) {
      entered.complete();
      return head.future;
    });
    final dio = AppDio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final failed = expectLater(
      dio.get<String>(url),
      throwsA(isA<DioException>()),
    );
    await entered.future;
    seed(age: Duration.zero, data: 'replacement');
    final replacement = cache.getCache(Uri.parse(url));
    head.completeError(StateError('old HEAD failed'));
    await failed;
    expect(cache.getCache(Uri.parse(url)), same(replacement));
  });

  test(
    'validation replays cookies once and retains HEAD cookie updates',
    () async {
      final previous = SingleInstanceCookieJar.instance;
      SingleInstanceCookieJar.instance = null;
      final jar = SingleInstanceCookieJar(':memory:');
      addTearDown(() {
        jar.dispose();
        SingleInstanceCookieJar.instance = previous;
      });
      jar.saveFromResponse(Uri.parse(url), [Cookie('session', 'one')]);
      seed(headers: {'cookie': 'session=one'});
      final adapter = _Adapter((options) async {
        expect(options.headers['cookie'], 'session=one');
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'set-cookie': ['session=two; Path=/'],
          },
        );
      });
      final dio = AppDio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      expect((await dio.get<String>(url)).data, 'cached');
      expect(adapter.methods, ['HEAD']);
      expect(jar.loadForRequestCookieHeader(Uri.parse(url)), 'session=two');
    },
  );

  test(
    'response representation changes cannot reuse a cached string as bytes',
    () async {
      seed(age: Duration.zero, responseType: ResponseType.plain);
      final adapter = _Adapter(
        (_) async => ResponseBody.fromString('bytes', 200),
      );
      final dio = AppDio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final response = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      expect(response.data, 'bytes'.codeUnits);
      expect(adapter.methods, ['GET']);
    },
  );

  test('validation consumes its body without reporting GET progress', () async {
    seed();
    final entered = Completer<void>();
    final body = StreamController<Uint8List>();
    final adapter = _Adapter((options) async {
      expect(options.method, 'HEAD');
      expect(options.responseType, ResponseType.bytes);
      expect(options.data, isNull);
      expect(options.headers.containsKey('cache-time'), isFalse);
      entered.complete();
      return ResponseBody(body.stream, 200);
    });
    final dio = AppDio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    var completed = false;
    var progress = 0;
    final request = dio
        .get<String>(
          url,
          options: Options(headers: {'cache-time': 'short'}),
          onReceiveProgress: (_, _) => progress++,
        )
        .then((response) {
          completed = true;
          return response;
        });
    await entered.future;
    body.add(Uint8List.fromList([1, 2, 3]));
    await pumpEventQueue();
    expect(completed, isFalse);
    expect(progress, 0);
    await body.close();
    expect((await request).data, 'cached');
    expect(adapter.methods, ['HEAD']);
  });

  for (final streaming in [false, true]) {
    test(
      'GET payload bypasses cache and preserves its body: stream=$streaming',
      () async {
        final contentType = streaming
            ? 'application/octet-stream'
            : 'application/json';
        seed(age: Duration.zero, headers: {'content-type': contentType});
        final cached = cache.getCache(Uri.parse(url));
        final adapter = _Adapter(
          (_) async => ResponseBody.fromString('filtered result', 200),
          consumeInput: true,
        );
        final dio = AppDio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        final response = await dio.get<String>(
          url,
          data: streaming
              ? Stream<Uint8List>.value(
                  Uint8List.fromList('new filter'.codeUnits),
                )
              : {'filter': 'new'},
          options: Options(headers: {'content-type': contentType}),
        );
        expect(response.data, 'filtered result');
        expect(adapter.methods, ['GET']);
        expect(String.fromCharCodes(adapter.upload), contains('new'));
        expect(cache.getCache(Uri.parse(url)), same(cached));
      },
    );
  }

  for (final cleanupFails in [false, true]) {
    test(
      'cancelled HEAD stays owned through late cleanup; fails=$cleanupFails',
      () async {
        seed();
        final entered = Completer<void>();
        final response = Completer<ResponseBody>();
        final adapter = _Adapter((_) {
          entered.complete();
          return response.future;
        });
        final dio = AppDio()..httpClientAdapter = adapter;
        final owner = OwnedDioClient(dio);
        final token = CancelToken();
        final cancelled = expectLater(
          dio.get<String>(url, cancelToken: token),
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'cancel',
              DioExceptionType.cancel,
            ),
          ),
        );
        await entered.future;
        token.cancel('caller closed');
        await cancelled;
        var closed = false;
        final close = owner.closeAndWait();
        final result = cleanupFails
            ? expectLater(
                close,
                throwsA(
                  isA<DioCleanupFailure>().having(
                    (e) => e.failures.map((f) => f.error.toString()).toList(),
                    'cleanup causes',
                    [
                      'Bad state: HEAD body close',
                      'Bad state: HEAD body cancel',
                    ],
                  ),
                ),
              )
            : close.then((_) => closed = true);
        await pumpEventQueue();
        expect(closed, isFalse);
        final cancelling = Completer<void>();
        final release = Completer<void>();
        final body = StreamController<Uint8List>(
          onCancel: () {
            cancelling.complete();
            return release.future;
          },
        );
        var bodyClosed = false;
        response.complete(
          ResponseBody(
            body.stream,
            200,
            onClose: () {
              bodyClosed = true;
              if (cleanupFails) throw StateError('HEAD body close');
            },
          ),
        );
        await cancelling.future;
        expect(bodyClosed, isTrue);
        expect(closed, isFalse);
        if (cleanupFails) {
          release.completeError(StateError('HEAD body cancel'));
        } else {
          release.complete();
        }
        await result;
        expect(owner.closeAndWait(), same(close));
        expect(adapter.methods, ['HEAD']);
        expect(adapter.closes, 1);
        await body.close();
      },
    );
  }

  for (final action in ['match', 'changed', 'close']) {
    test(
      'native cache revalidation uses and releases its original adapter: $action',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final address = 'http://127.0.0.1:${server.port}/native';
        final methods = <String>[];
        final headEntered = Completer<void>();
        server.listen((request) {
          methods.add(request.method);
          if (request.method == 'HEAD') {
            headEntered.complete();
            if (action == 'close') return;
          }
          request.response.headers.contentType = ContentType.text;
          request.response.headers.contentLength = 6;
          request.response.headers.set(
            'etag',
            action == 'changed' && methods.length > 1 ? 'second' : 'first',
          );
          if (request.method == 'GET') request.response.write('native');
          unawaited(request.response.close());
        });
        final adapter = _NativeAdapter();
        final dio = AppDio()..httpClientAdapter = adapter;
        addTearDown(() async {
          dio.close(force: true);
          await adapter.waitForIdle();
          await server.close(force: true);
        });
        Future<Response<String>> get() => dio.get<String>(
          address,
          options: Options(headers: {'user-agent': 'cache-owner-native'}),
        );
        expect((await get()).data, 'native');
        final first = cache.getCache(Uri.parse(address))!;
        cache.setCache(
          NetworkCache(
            uri: first.uri,
            requestHeaders: first.requestHeaders,
            responseHeaders: first.responseHeaders,
            data: first.data,
            time: DateTime.now().subtract(const Duration(minutes: 1)),
            size: first.size,
            responseType: first.responseType,
          ),
        );
        final request = get();
        final result = action == 'close'
            ? expectLater(request, throwsA(isA<DioException>()))
            : request.then((value) {
                expect(value.data, 'native');
                expect(
                  value.headers.value('venera-cache'),
                  action == 'match' ? 'true' : isNull,
                );
              });
        await headEntered.future.timeout(const Duration(seconds: 10));
        if (action == 'close') dio.close(force: true);
        await result.timeout(const Duration(seconds: 10));
        await adapter.waitForIdle().timeout(const Duration(seconds: 10));
        expect(
          methods,
          action == 'changed' ? ['GET', 'HEAD', 'GET'] : ['GET', 'HEAD'],
        );
        expect(adapter.methods, methods);
      },
      skip: !Platform.isWindows,
    );
  }
}

class _NativeAdapter extends RHttpAdapter {
  final methods = <String>[];
  @override
  Future<rhttp.ClientSettings> get settings async => const rhttp.ClientSettings(
    proxySettings: rhttp.ProxySettings.noProxy(),
    throwOnStatusCode: false,
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    methods.add(options.method);
    return super.fetch(options, requestStream, cancelFuture);
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond, {this.consumeInput = false});
  final Future<ResponseBody> Function(RequestOptions) respond;
  final bool consumeInput;
  final upload = <int>[];
  final methods = <String>[];
  int closes = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    methods.add(options.method);
    if (consumeInput && requestStream != null) {
      await for (final chunk in requestStream) {
        upload.addAll(chunk);
      }
    }
    return respond(options);
  }

  @override
  void close({bool force = false}) => closes++;
}
