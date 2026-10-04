import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/rhttp_stream_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    App.version = 'rhttp-lifecycle-test';
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });

  test(
    'Dio cancellation and Dart stream done cannot finish native ownership',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(start: native.start);
      final dio = Dio()..httpClientAdapter = adapter;
      final token = CancelToken();
      final response = dio.get<List<int>>(
        'http://example.test',
        cancelToken: token,
      );
      final cancelled = expectLater(response, throwsA(isA<DioException>()));
      await native.started.future;
      token.cancel();
      await cancelled;
      native.headers.completeError(StateError('native request cancelled'));
      await native.body.close();
      await native.cancelled.future;
      var idle = false;
      final waiting = adapter.waitForIdle().then((_) => idle = true);
      await pumpEventQueue();
      expect(idle, isFalse);
      native.finished.complete();
      await waiting;
      expect(idle, isTrue);
      dio.close(force: true);
    },
  );

  for (final duringCleanup in [false, true]) {
    test('Dio partial response cancellation keeps cleanup errors on idle only; '
        'cleanup already started=$duringCleanup', () async {
      final nativeFailure = StateError('native completion failed');
      final uploadFailure = StateError('upload release failed');
      final responseFailure = StateError('response release failed');
      final failures = <RHttpCleanupError>[
        (
          stage: 'await native completion',
          error: nativeFailure,
          stack: StackTrace.current,
        ),
        (
          stage: 'release upload sender',
          error: uploadFailure,
          stack: StackTrace.current,
        ),
        (
          stage: 'release response subscription',
          error: responseFailure,
          stack: StackTrace.current,
        ),
      ];
      final native = _HeldCall();
      final responseCancelling = Completer<void>();
      final responseReleased = Completer<void>();
      native.body.onCancel = () {
        responseCancelling.complete();
        return responseReleased.future;
      };
      final adapter = _Adapter(start: native.start);
      final dio = Dio()..httpClientAdapter = adapter;
      final token = CancelToken();
      final received = Completer<void>();
      final request = dio.get<List<int>>(
        'http://example.test',
        options: Options(responseType: ResponseType.bytes),
        cancelToken: token,
        onReceiveProgress: (_, _) {
          if (!received.isCompleted) received.complete();
        },
      );
      final cancelled = expectLater(
        request,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await native.started.future;
      native.respond();
      native.body.add(Uint8List.fromList([1]));
      await received.future;
      void finishNative() =>
          native.finished.completeError(RHttpCleanupFailure(failures.take(2)));
      if (duringCleanup) {
        finishNative();
        await responseCancelling.future;
      }
      token.cancel();
      await cancelled;
      if (!duringCleanup) {
        await native.cancelled.future;
        finishNative();
        await responseCancelling.future;
      }
      final retained = isA<RHttpCleanupFailure>().having(
        (error) => error.failures,
        'original cleanup errors and stacks',
        unorderedEquals(failures),
      );
      var idle = false;
      final waiting = expectLater(
        adapter.waitForIdle().whenComplete(() => idle = true),
        throwsA(retained),
      );
      await pumpEventQueue();
      expect(idle, isFalse);
      responseReleased.completeError(responseFailure, failures.last.stack);
      await waiting;
      await expectLater(adapter.waitForIdle(), throwsA(retained));
      // Dio discards responseSubscription.cancel()'s Future. Its cancellation
      // branch must not report the same failures outside the owning idle wait.
      await pumpEventQueue();
      dio.close(force: true);
      unawaited(native.body.close());
    });
  }

  test(
    'consumer cancel joins delayed native exit after body error and done',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      await native.started.future;
      native.respond();
      final response = await result;
      final errors = <Object>[];
      final listener = response.stream.listen((_) {}, onError: errors.add);
      final failure = StateError('response failed');
      native.body.addError(failure);
      await native.body.close();
      await pumpEventQueue();
      expect(errors, [same(failure)]);
      var cancelled = false;
      final cancellation = listener.cancel().then((_) => cancelled = true);
      await native.cancelled.future;
      await pumpEventQueue();
      expect(cancelled, isFalse);
      native.finished.complete();
      await cancellation;
      await adapter.waitForIdle();
    },
  );

  for (final duringCleanup in [false, true]) {
    test('consumer cancel joins failed cleanup and preserves done; '
        'cleanup already started=$duringCleanup', () async {
      final native = _HeldCall();
      final responseCancelling = Completer<void>();
      final responseReleased = Completer<void>();
      final failures = <RHttpCleanupError>[
        (
          stage: 'finish native request',
          error: StateError('native completion failed'),
          stack: StackTrace.current,
        ),
        (
          stage: 'release response subscription',
          error: StateError('response release failed'),
          stack: StackTrace.current,
        ),
      ];
      native.body.onCancel = () {
        responseCancelling.complete();
        return responseReleased.future;
      };
      final request = RHttpStreamRequest(
        options: RequestOptions(path: 'http://example.test'),
        settings: Future.value(_settings),
        upload: null,
        statusMessage: (_) => 'OK',
        start: native.start,
      );
      final retained = isA<RHttpCleanupFailure>().having(
        (error) => error.failures,
        'original cleanup errors and stacks',
        unorderedEquals(failures),
      );
      var done = false;
      final completed = expectLater(
        request.done.whenComplete(() => done = true),
        throwsA(retained),
      );
      await native.started.future;
      native.respond();
      final received = Completer<void>();
      final subscription = (await request.response).stream.listen((_) {
        if (!received.isCompleted) received.complete();
      });
      native.body.add(Uint8List.fromList([1]));
      await received.future;
      void finishNative() => native.finished.completeError(
        failures.first.error,
        failures.first.stack,
      );
      if (duringCleanup) {
        finishNative();
        await responseCancelling.future;
      }
      var cancelled = false;
      final cancelling = subscription.cancel().then((_) => cancelled = true);
      await pumpEventQueue();
      expect(cancelled, isFalse);
      expect(done, isFalse);
      if (!duringCleanup) {
        await native.cancelled.future;
        finishNative();
        await responseCancelling.future;
      }
      await pumpEventQueue();
      expect(cancelled, isFalse);
      expect(done, isFalse);
      responseReleased.completeError(failures.last.error, failures.last.stack);
      await cancelling;
      await completed;
      expect(done, isTrue);
      await expectLater(request.done, throwsA(retained));
      unawaited(native.body.close());
    });
  }

  for (final paused in [false, true]) {
    test(
      'force close joins native with ${paused ? 'paused' : 'unconsumed'} response',
      () async {
        final native = _HeldCall();
        final adapter = _Adapter(start: native.start);
        final result = adapter.fetch(
          RequestOptions(path: 'http://example.test'),
          null,
          null,
        );
        await native.started.future;
        native.respond();
        final response = await result;
        final subscription = paused ? response.stream.listen((_) {}) : null;
        subscription?.pause();
        adapter.close(force: true);
        adapter.close(force: true);
        await native.cancelled.future;
        native.body.add(Uint8List.fromList([1]));
        await native.body.close();
        var idle = false;
        final waiting = adapter.waitForIdle().then((_) => idle = true);
        await pumpEventQueue();
        expect(idle, isFalse);
        native.finished.complete();
        await waiting;
        expect(native.cancels, 1);
        await subscription?.cancel();
        await expectLater(
          adapter.fetch(
            RequestOptions(path: 'http://example.test'),
            null,
            null,
          ),
          throwsStateError,
        );
      },
    );
  }

  test('close without force allows accepted requests to complete', () async {
    final native = _HeldCall();
    final adapter = _Adapter(start: native.start);
    final result = adapter.fetch(
      RequestOptions(path: 'http://example.test'),
      null,
      null,
    );
    await native.started.future;
    adapter.close();
    native.respond();
    final bytes = (await result).stream.expand((chunk) => chunk).toList();
    native.body.add(Uint8List.fromList([1, 2, 3]));
    await native.body.close();
    expect(native.cancels, 0);
    native.finished.complete();
    expect(await bytes, [1, 2, 3]);
    await adapter.waitForIdle();
    expect(native.cancels, 0);
  });

  test(
    'settings cancellation waits for preparation but never dispatches',
    () async {
      final native = _HeldCall();
      final settings = Completer<rhttp.ClientSettings>();
      final adapter = _Adapter(
        start: native.start,
        configured: settings.future,
      );
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      final cancellation = expectLater(result, throwsA(isA<DioException>()));
      adapter.close(force: true);
      var idle = false;
      final waiting = adapter.waitForIdle().then((_) => idle = true);
      await pumpEventQueue();
      expect(idle, isFalse);
      settings.complete(_settings);
      await cancellation;
      await waiting;
      expect(native.started.isCompleted, isFalse);
      unawaited(native.body.close());
    },
  );

  test(
    'cleanup failures are aggregated and repeated waits retain them',
    () async {
      final native = _HeldCall(cancelError: StateError('cancel failed'));
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      await native.started.future;
      native.respond();
      await result;
      adapter.close(force: true);
      await native.cancelled.future;
      await native.body.close();
      native.finished.completeError(StateError('native join failed'));
      final matcher = isA<RHttpCleanupFailure>().having(
        (f) => f.failures.length,
        'both failures',
        2,
      );
      await expectLater(adapter.waitForIdle(), throwsA(matcher));
      await expectLater(adapter.waitForIdle(), throwsA(matcher));
    },
  );

  test(
    'failed response is a request error and idle still joins native',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      final failure = StateError('connection refused');
      final failed = expectLater(result, throwsA(same(failure)));
      await native.started.future;
      native.headers.completeError(failure);
      await native.body.close();
      await failed;
      native.finished.complete();
      await adapter.waitForIdle();
    },
  );

  test(
    'failed native completion cancels an unclosed body and retains all cleanup failures',
    () async {
      final requestFailure = StateError('headers failed');
      final nativeFailure = StateError('native completion failed');
      final cancelFailure = StateError('native cancellation failed');
      final bodyFailure = StateError('body subscription release failed');
      final native = _HeldCall(cancelError: cancelFailure);
      var bodyCancels = 0;
      native.body.onCancel = () {
        bodyCancels++;
        throw bodyFailure;
      };
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      final failedRequest = expectLater(result, throwsA(same(requestFailure)));
      await native.started.future;
      native.headers.completeError(requestFailure);
      await native.cancelled.future;
      native.finished.completeError(nativeFailure);
      await failedRequest;
      final failures = isA<RHttpCleanupFailure>().having(
        (error) => error.failures.map((failure) => failure.error).toList(),
        'all cleanup failures',
        unorderedEquals([
          same(nativeFailure),
          same(cancelFailure),
          same(bodyFailure),
        ]),
      );
      // The body is intentionally never closed: failed native completion must
      // cancel it rather than wait forever for an onDone that cannot arrive.
      await expectLater(
        adapter.waitForIdle().timeout(const Duration(seconds: 1)),
        throwsA(failures),
      );
      await expectLater(adapter.waitForIdle(), throwsA(failures));
      expect(bodyCancels, 1);
      unawaited(native.body.close());
    },
  );

  test(
    'successful native completion still drains later queued body events',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      await native.started.future;
      native.respond();
      final bytes = (await result).stream.expand((chunk) => chunk).toList();
      native.finished.complete();
      var idle = false;
      final waiting = adapter.waitForIdle().then((_) => idle = true);
      await pumpEventQueue();
      expect(idle, isFalse);
      native.body.add(Uint8List.fromList([1, 2, 3]));
      await native.body.close();
      await waiting;
      expect(await bytes, [1, 2, 3]);
      expect(native.cancels, 0);
    },
  );

  test(
    'natural body completion does not leak cleanup failure outside idle',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(start: native.start);
      final result = adapter.fetch(
        RequestOptions(path: 'http://example.test'),
        null,
        null,
      );
      await native.started.future;
      native.respond();
      final consumed = (await result).stream.toList();
      native.body.add(Uint8List.fromList([1]));
      await native.body.close();
      native.finished.completeError(StateError('release failed'));
      expect(await consumed, hasLength(1));
      await expectLater(
        adapter.waitForIdle(),
        throwsA(isA<RHttpCleanupFailure>()),
      );
    },
  );

  test(
    'failed dispatch cleanup is retained even after Dio cancellation',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final failure = RHttpCleanupFailure([
        (
          stage: 'release failed upload',
          error: StateError('release failed'),
          stack: StackTrace.current,
        ),
      ]);
      final adapter = _Adapter(
        start: (options, settings, upload) async {
          started.complete();
          await release.future;
          throw failure;
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final token = CancelToken();
      final request = dio.get<void>('http://example.test', cancelToken: token);
      final cancelled = expectLater(request, throwsA(isA<DioException>()));
      await started.future;
      token.cancel();
      await cancelled;
      release.complete();
      await expectLater(
        adapter.waitForIdle(),
        throwsA(isA<RHttpCleanupFailure>()),
      );
      dio.close(force: true);
    },
  );

  for (final partial in [false, true]) {
    test(
      'native request cancellation closes peer; partial body=$partial',
      () async {
        final server = await _Peer.start(partial: partial);
        final adapter = _Adapter();
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() async {
          dio.close(force: true);
          await adapter.waitForIdle();
          await server.close();
        });
        final token = CancelToken();
        final request = dio.get<List<int>>(
          server.url,
          options: Options(responseType: ResponseType.bytes),
          cancelToken: token,
        );
        final cancelled = expectLater(request, throwsA(isA<DioException>()));
        await server.requested.future.timeout(const Duration(seconds: 10));
        token.cancel();
        await cancelled;
        await adapter.waitForIdle().timeout(const Duration(seconds: 10));
        await server.disconnected.future.timeout(const Duration(seconds: 10));
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'native upload cancellation waits for upstream release',
    () async {
      final release = Completer<void>();
      final cancelling = Completer<void>();
      final input = StreamController<Uint8List>(
        onCancel: () {
          cancelling.complete();
          return release.future;
        },
      );
      final server = await _Peer.start(partial: false);
      final adapter = _Adapter();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        adapter.close(force: true);
        await adapter.waitForIdle();
        await server.close();
        unawaited(input.close());
      });
      final request = adapter.fetch(
        RequestOptions(path: server.url, method: 'POST'),
        input.stream,
        null,
      );
      final failed = expectLater(request, throwsA(anything));
      input.add(Uint8List(1024 * 1024));
      await server.requested.future.timeout(const Duration(seconds: 10));
      adapter.close(force: true);
      await failed;
      await cancelling.future.timeout(const Duration(seconds: 10));
      var idle = false;
      final waiting = adapter.waitForIdle().then((_) => idle = true);
      await pumpEventQueue();
      expect(idle, isFalse);
      release.complete();
      await waiting.timeout(const Duration(seconds: 10));
    },
    skip: !Platform.isWindows,
  );

  test('native successful upload returns complete bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final adapter = _Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final received = Completer<List<int>>();
    server.listen((request) async {
      received.complete(await request.expand((chunk) => chunk).toList());
      request.response.write('complete');
      await request.response.close();
    });
    addTearDown(() async {
      dio.close(force: true);
      await adapter.waitForIdle();
      await server.close(force: true);
    });
    final response = await dio.post<String>(
      'http://127.0.0.1:${server.port}',
      data: 'upload payload',
    );
    expect(response.data, 'complete');
    expect(utf8.decode(await received.future), 'upload payload');
    await adapter.waitForIdle();
  }, skip: !Platform.isWindows);
}

const _settings = rhttp.ClientSettings(
  proxySettings: rhttp.ProxySettings.noProxy(),
  throwOnStatusCode: false,
);

class _Adapter extends RHttpAdapter {
  _Adapter({RHttpStreamCallFactory? start, this.configured})
    : super(startStreamCall: start);
  final Future<rhttp.ClientSettings>? configured;
  @override
  Future<rhttp.ClientSettings> get settings =>
      configured ?? Future.value(_settings);
}

class _HeldCall {
  _HeldCall({this.cancelError});
  final Object? cancelError;
  final started = Completer<void>();
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  final headers =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();
  int cancels = 0;

  void respond() =>
      headers.complete((statusCode: 200, headers: <String, List<String>>{}));
  Future<RHttpStreamCall> start(
    RequestOptions options,
    rhttp.ClientSettings settings,
    Stream<Uint8List>? upload,
  ) async {
    started.complete();
    return RHttpStreamCall(
      response: headers.future,
      body: body.stream,
      finished: finished.future,
      cancel: () async {
        cancels++;
        if (!cancelled.isCompleted) cancelled.complete();
        if (cancelError != null) throw cancelError!;
      },
    );
  }
}

class _Peer {
  _Peer(this.server, this.partial) {
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (bytes) {
          if (!requested.isCompleted) {
            requested.complete();
            if (partial) {
              socket.write('HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\nx');
              unawaited(socket.flush());
            }
          }
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
          socket.destroy();
        },
        onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
          socket.destroy();
        },
      );
    });
  }
  final ServerSocket server;
  final bool partial;
  final sockets = <Socket>[];
  final requested = Completer<void>();
  final disconnected = Completer<void>();
  String get url => 'http://127.0.0.1:${server.port}';
  static Future<_Peer> start({required bool partial}) async =>
      _Peer(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), partial);
  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}
