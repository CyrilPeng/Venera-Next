import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('close waits for native idle even when force close fails', () async {
    final cause = StateError('request failed');
    final causeStack = StackTrace.fromString('request stack');
    final closeError = StateError('close failed');
    final closeStack = StackTrace.fromString('close stack');
    final drainError = StateError('upload release failed');
    final drainStack = StackTrace.fromString('upload release stack');
    final adapter = _CleanupAdapter(
      closeError: closeError,
      closeStack: closeStack,
    );
    final client = _endpoint.createClient(adapter: adapter);
    var completed = false;
    final closing = closeWebDavClient(
      client,
      cause: cause,
      stackTrace: causeStack,
    ).whenComplete(() => completed = true);
    final failure = expectLater(
      closing,
      throwsA(
        isA<WebDavClientCleanupFailure>()
            .having((error) => error.cause, 'request cause', same(cause))
            .having(
              (error) => error.stackTrace,
              'request stack',
              same(causeStack),
            )
            .having(
              (error) => error.failures,
              'original cleanup failures and stacks',
              [
                (
                  stage: 'close WebDAV client',
                  error: closeError,
                  stack: closeStack,
                ),
                (
                  stage: 'release upload sender',
                  error: drainError,
                  stack: drainStack,
                ),
              ],
            ),
      ),
    );
    await adapter.waiting.future;
    expect(adapter.forced, isTrue);
    await pumpEventQueue();
    expect(completed, isFalse);
    adapter.release.completeError(
      RHttpCleanupFailure([
        (stage: 'release upload sender', error: drainError, stack: drainStack),
      ]),
    );
    await failure;
  });

  test('successful cleanup does not replace a request failure', () async {
    final adapter = _CleanupAdapter()..release.complete();
    final client = _endpoint.createClient(adapter: adapter);
    final cause = StateError('HTTP request failed');
    final stack = StackTrace.fromString('HTTP stack');
    Future<void> request() async {
      try {
        Error.throwWithStackTrace(cause, stack);
      } finally {
        await closeWebDavClient(client, cause: cause, stackTrace: stack);
      }
    }

    try {
      await request();
      fail('The original request must fail');
    } catch (error, actualStack) {
      expect(error, same(cause));
      expect(actualStack.toString(), stack.toString());
    }
    expect(adapter.closes, 1);
  });

  test('drain retains the adapter captured before close changes it', () async {
    final adapter = _CleanupAdapter();
    final replacement = _CleanupAdapter()..release.complete();
    final client = _endpoint.createClient(adapter: adapter);
    adapter.onClose = () => client.c.httpClientAdapter = replacement;
    final closing = closeWebDavClient(client);
    await adapter.waiting.future;
    expect(replacement.waiting.isCompleted, isFalse);
    adapter.release.complete();
    await closing;
    expect(adapter.closes, 1);
    expect(replacement.closes, 0);
  });

  test('non-rhttp clients close without a native drain', () async {
    final adapter = _OrdinaryAdapter();
    await closeWebDavClient(_endpoint.createClient(adapter: adapter));
    expect(adapter.closed, isTrue);
    expect(adapter.forced, isTrue);
  });

  test('cleanup-only failure has no invented request cause', () async {
    final error = StateError('close failed');
    final stack = StackTrace.fromString('close only');
    final adapter = _CleanupAdapter(closeError: error, closeStack: stack)
      ..release.complete();
    await expectLater(
      closeWebDavClient(_endpoint.createClient(adapter: adapter)),
      throwsA(
        isA<WebDavClientCleanupFailure>()
            .having((error) => error.cause, 'cause', isNull)
            .having((error) => error.stackTrace, 'cause stack', isNull)
            .having(
              (error) => error.failures.single.error,
              'close failure',
              same(error),
            ),
      ),
    );
    expect(adapter.waiting.isCompleted, isTrue);
  });

  test(
    'native WebDAV failure waits for delayed upload subscription release',
    () async {
      await rhttp.Rhttp.init();
      final previousVersion = App.version;
      final previousProxy = appdata.settings['proxy'];
      final previousInitialized = App.isInitialized;
      App.version = 'webdav-client-lifecycle-test';
      appdata.settings['proxy'] = 'direct';
      App.isInitialized = false;
      final uploadReleased = Completer<void>();
      final uploadCancelling = Completer<void>();
      final upload = StreamController<Uint8List>(
        onCancel: () {
          uploadCancelling.complete();
          return uploadReleased.future;
        },
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final received = Completer<void>();
      server.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {
          if (!received.isCompleted) received.complete();
          socket.destroy();
        }, onError: (Object _) {});
      });
      final client = WebDavEndpoint(
        url: 'http://127.0.0.1:${server.port}/dav',
        user: '',
        password: '',
      ).createClient();
      client.c.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.method, 'PROPFIND');
            // Keep the production WebDAV request builder and native transport;
            // this request body lets the test hold upload resource release.
            options.data = upload.stream;
            handler.next(options);
          },
        ),
      );
      addTearDown(() async {
        if (!uploadReleased.isCompleted) uploadReleased.complete();
        await closeWebDavClient(client);
        unawaited(upload.close());
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
        App.version = previousVersion;
        appdata.settings['proxy'] = previousProxy;
        App.isInitialized = previousInitialized;
      });
      final failed = expectLater(
        client.readDir('/'),
        throwsA(isA<DioException>()),
      );
      await received.future.timeout(const Duration(seconds: 10));
      await failed.timeout(const Duration(seconds: 10));
      await uploadCancelling.future.timeout(const Duration(seconds: 10));
      var closed = false;
      final closing = closeWebDavClient(client).then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      uploadReleased.complete();
      await closing.timeout(const Duration(seconds: 10));
      expect(closed, isTrue);
    },
    skip: !Platform.isWindows,
  );
}

final _endpoint = WebDavEndpoint(
  url: 'http://example.test',
  user: '',
  password: '',
);

class _CleanupAdapter extends RHttpAdapter {
  _CleanupAdapter({this.closeError, this.closeStack});
  final Object? closeError;
  final StackTrace? closeStack;
  final waiting = Completer<void>();
  final release = Completer<void>();
  void Function()? onClose;
  int closes = 0;
  bool forced = false;

  @override
  void close({bool force = false}) {
    closes++;
    forced = force;
    onClose?.call();
    if (closeError != null) {
      Error.throwWithStackTrace(closeError!, closeStack!);
    }
  }

  @override
  Future<void> waitForIdle() {
    waiting.complete();
    return release.future;
  }
}

class _OrdinaryAdapter implements HttpClientAdapter {
  bool closed = false;
  bool forced = false;

  @override
  void close({bool force = false}) {
    closed = true;
    forced = force;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => throw UnimplementedError();
}
