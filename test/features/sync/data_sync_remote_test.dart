import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/features/sync/data_sync_remote.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/rhttp_stream_request.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final previousVersion = App.version;
    App.version = 'data-sync-remote-test';
    addTearDown(() => App.version = previousVersion);
  });

  test(
    'closed remote rejects every SDK entry before touching local targets',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(native.start);
      final remote = WebDavDataSyncRemote(
        WebDavEndpoint(url: 'http://example.test', user: '', password: ''),
        createClient: (connection) => connection.createClient(adapter: adapter),
      );
      final directory = Directory.systemTemp.createTempSync(
        'closed-sync-remote-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final existing = File('${directory.path}/existing.venera')
        ..writeAsBytesSync([7, 8, 9]);
      final absent = File('${directory.path}/absent/snapshot.venera');
      await remote.dispose();
      for (final action in <Future<Object?> Function()>[
        remote.listNames,
        () => remote.probeArchive('remote.venera'),
        () => remote.createArchiveIfAbsent(
          'remote.venera',
          existing,
          sha256: sha256.convert([7, 8, 9]).toString(),
          length: 3,
        ),
        () => remote.removeArchiveIfUnchanged(
          'remote.venera',
          strongEtag: '"existing"',
        ),
        () => remote.readToFile('remote.venera', existing.path),
        () => remote.readToFile('remote.venera', absent.path),
      ]) {
        await expectLater(action(), throwsA(isA<DioException>()));
      }
      expect(existing.readAsBytesSync(), [7, 8, 9]);
      expect(absent.existsSync(), isFalse);
      expect(absent.parent.existsSync(), isFalse);
      expect(native.calls, 0);
      expect(adapter.closes, 1);
    },
  );

  for (final failCleanup in [false, true]) {
    test('remote dispose joins late native completion and is idempotent; '
        'cleanup fails=$failCleanup', () async {
      final native = _HeldCall();
      final adapter = _Adapter(native.start);
      final endpoint = WebDavEndpoint(
        url: 'http://example.test/RemoteRoot',
        user: '',
        password: '',
      );
      var creations = 0;
      final remote = WebDavDataSyncRemote(
        endpoint,
        createClient: (connection) {
          expect(connection, same(endpoint));
          creations++;
          return connection.createClient(adapter: adapter);
        },
      );
      final requestError = StateError('remote disconnected');
      final requestStack = StackTrace.fromString('WebDAV request stack');
      final requesting = remote.listNames();
      final failed = expectLater(
        requesting,
        throwsA(
          isA<DioException>()
              .having(
                (error) => error.error,
                'request cause',
                same(requestError),
              )
              .having(
                (error) => error.stackTrace.toString(),
                'Dio request origin',
                contains('WebDavDataSyncRemote.listNames'),
              ),
        ),
      );
      final options = await native.started.future;
      expect(options.method, 'PROPFIND');
      expect(options.uri.path, '/RemoteRoot/');
      native.response.completeError(requestError, requestStack);
      await failed;
      await native.cancelled.future;
      var closed = false;
      final closing = remote.dispose();
      expect(remote.dispose(), same(closing));
      final finished = closing.then<void>(
        (_) => closed = true,
        onError: (Object error, StackTrace stack) {
          closed = true;
          Error.throwWithStackTrace(error, stack);
        },
      );
      final cleanupError = StateError('native upload release failed');
      final cleanupStack = StackTrace.fromString('native cleanup stack');
      final retained = isA<WebDavClientCleanupFailure>()
          .having((error) => error.cause, 'request owned by transfer', isNull)
          .having((error) => error.failures, 'native cleanup cause and stack', [
            (
              stage: 'release upload sender',
              error: cleanupError,
              stack: cleanupStack,
            ),
          ]);
      final expected = failCleanup
          ? expectLater(finished, throwsA(retained))
          : expectLater(finished, completes);
      await pumpEventQueue();
      expect(closed, isFalse);
      await native.body.close();
      await pumpEventQueue();
      expect(closed, isFalse);
      if (failCleanup) {
        native.finished.completeError(
          RHttpCleanupFailure([
            (
              stage: 'release upload sender',
              error: cleanupError,
              stack: cleanupStack,
            ),
          ]),
        );
      } else {
        native.finished.complete();
      }
      await expected;
      expect(remote.dispose(), same(closing));
      if (failCleanup) {
        await expectLater(remote.dispose(), throwsA(retained));
      } else {
        await remote.dispose();
      }
      expect(creations, 1);
      expect(adapter.closes, 1);
      expect(adapter.forced, isTrue);
      await expectLater(remote.listNames(), throwsA(isA<DioException>()));
      expect(native.calls, 1);
    });
  }

  test(
    'dispose begins cancellation before native request acknowledges it',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(native.start);
      final remote = WebDavDataSyncRemote(
        WebDavEndpoint(url: 'http://example.test', user: '', password: ''),
        createClient: (connection) => connection.createClient(adapter: adapter),
      );
      final request = remote.listNames();
      final failed = expectLater(request, throwsA(isA<DioException>()));
      await native.started.future;
      final closing = remote.dispose();
      await native.cancelled.future;
      expect(adapter.closes, 1);
      native.response.completeError(StateError('cancel acknowledged'));
      await failed;
      await native.body.close();
      native.finished.complete();
      await closing;
    },
  );

  for (final nativeFails in [false, true]) {
    test(
      'GET evidence waits for actual native completion; failure=$nativeFails',
      () async {
        final native = _HeldCall();
        final adapter = _Adapter(native.start);
        final remote = WebDavDataSyncRemote(
          WebDavEndpoint(url: 'http://example.test', user: '', password: ''),
          createClient: (connection) =>
              connection.createClient(adapter: adapter),
        );
        var settled = false;
        final probing = remote
            .probeArchive('snapshot.venera')
            .whenComplete(() => settled = true);
        final checked = nativeFails
            ? expectLater(probing, throwsA(isA<RHttpCleanupFailure>()))
            : expectLater(probing, completes);
        await native.started.future;
        native.response.complete((
          statusCode: 200,
          headers: <String, List<String>>{},
        ));
        native.body.add(Uint8List.fromList([1, 2, 3]));
        await native.body.close();
        await pumpEventQueue();
        expect(settled, isFalse);
        if (nativeFails) {
          native.finished.completeError(
            StateError('native GET did not finish successfully'),
          );
        } else {
          native.finished.complete();
        }
        await checked;
        if (nativeFails) {
          await expectLater(
            remote.dispose(),
            throwsA(isA<WebDavClientCleanupFailure>()),
          );
        } else {
          await remote.dispose();
        }
      },
    );
  }
}

class _Adapter extends RHttpAdapter {
  _Adapter(RHttpStreamCallFactory start) : super(startStreamCall: start);
  int closes = 0;
  bool forced = false;

  @override
  Future<rhttp.ClientSettings> get settings async =>
      const rhttp.ClientSettings(proxySettings: rhttp.ProxySettings.noProxy());

  @override
  void close({bool force = false}) {
    closes++;
    forced = force;
    super.close(force: force);
  }
}

class _HeldCall {
  final started = Completer<RequestOptions>();
  final response =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();
  final finished = Completer<void>();
  final cancelled = Completer<void>();
  int calls = 0;

  Future<RHttpStreamCall> start(
    RequestOptions options,
    rhttp.ClientSettings settings,
    Stream<Uint8List>? upload,
  ) async {
    calls++;
    started.complete(options);
    return RHttpStreamCall(
      response: response.future,
      body: body.stream,
      finished: finished.future,
      cancel: () async {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
  }
}
