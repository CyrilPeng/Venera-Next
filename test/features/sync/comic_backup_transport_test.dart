import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/features/sync/comic_backup.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/rhttp_stream_request.dart';
import 'package:venera_next/network/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late File source;
  late File destination;
  final config = BackupConfig(
    url: 'https://backup.example.test/DavRoot',
    user: 'reader',
    pass: 'secret',
    remotePath: '/Backups/',
  );
  const remote = '/Backups/中文.cbz';
  const bytes = [80, 75, 3, 4, 1, 2, 255];

  setUp(() async {
    final previousVersion = App.version;
    App.version = 'comic-backup-transport-test';
    addTearDown(() => App.version = previousVersion);
    temporary = await Directory.systemTemp.createTemp(
      'comic-backup-transport-',
    );
    source = await File('${temporary.path}/source.cbz').writeAsBytes(bytes);
    destination = File('${temporary.path}/download.cbz');
    addTearDown(() => temporary.delete(recursive: true));
  });

  for (final entry in _Entry.values) {
    test('${entry.name} joins native exit after an early SDK error', () async {
      final native = _HeldCall();
      final adapter = _Adapter(native.start);
      _retire(native, adapter);
      var creations = 0;
      final ops = WebDavComicBackupOps(
        createClient: (received) {
          expect(received, same(config));
          creations++;
          return received.endpoint.createClient(adapter: adapter);
        },
      );
      final result = _Observed(
        _invoke(entry, ops, config, source.path, destination.path, remote),
      );
      final options = await native.started.future;
      _expectRequest(entry, options);
      final cause = StateError('${entry.name} response failed');
      final stack = StackTrace.fromString(
        '${entry.name} original request stack',
      );
      final sdkFailure = DioException(
        requestOptions: options,
        error: cause,
        stackTrace: stack,
      );
      native.headers.completeError(sdkFailure, stack);
      await adapter.closed.future;
      await native.cancelled.future;
      await pumpEventQueue();
      expect(result.settled, isFalse);
      expect(adapter.closes, 1);
      expect(adapter.forced, isTrue);
      await native.body.close();
      await pumpEventQueue();
      expect(result.settled, isFalse, reason: 'body EOF is not native exit');
      native.finished.complete();
      final outcome = await result.done;
      expect(outcome.error, same(sdkFailure));
      expect(
        outcome.error,
        isA<DioException>()
            .having((error) => error.error, 'original cause', same(cause))
            .having(
              (error) => error.stackTrace.toString(),
              'original request stack',
              stack.toString(),
            ),
      );
      expect(creations, 1);
      expect(adapter.closes, 1);
      expect(
        native.calls,
        entry == _Entry.upload ? 3 : (entry == _Entry.download ? 2 : 1),
      );
      if (entry == _Entry.upload) expect(native.uploadBytes, bytes);
      expect(await source.readAsBytes(), bytes);
    });

    test(
      '${entry.name} preserves successful SDK semantics and closes once',
      () async {
        final native = _HeldCall();
        final adapter = _Adapter(native.start);
        _retire(native, adapter);
        final ops = WebDavComicBackupOps(
          createClient: (received) =>
              received.endpoint.createClient(adapter: adapter),
        );
        final result = _Observed(
          _invoke(entry, ops, config, source.path, destination.path, remote),
        );
        final options = await native.started.future;
        _expectRequest(entry, options);
        final status = switch (entry) {
          _Entry.check || _Entry.list || _Entry.exists => 207,
          _Entry.directory || _Entry.upload => 201,
          _Entry.download => 200,
          _Entry.delete => 204,
        };
        final payload = switch (entry) {
          _Entry.check ||
          _Entry.list ||
          _Entry.exists => utf8.encode(_directoryXml),
          _Entry.download => bytes,
          _ => <int>[],
        };
        native.respond(status, payload);
        await native.body.close();
        await pumpEventQueue();
        expect(result.settled, isFalse);
        native.finished.complete();
        final outcome = await result.done;
        expect(outcome.error, isNull);
        switch (entry) {
          case _Entry.list:
            expect(outcome.value, [
              BackupFile(
                name: '中文.cbz',
                size: 7,
                modified: DateTime.utc(2026, 10, 4, 1, 2, 3).toLocal(),
              ),
              BackupFile(
                name: 'unknown.cbz',
                size: 0,
                modified: DateTime.fromMillisecondsSinceEpoch(0),
              ),
            ]);
          case _Entry.exists:
            expect(outcome.value, isTrue);
          case _Entry.upload:
            expect(native.uploadBytes, bytes);
            expect(
              options.headers[HttpHeaders.contentLengthHeader],
              bytes.length,
            );
          case _Entry.download:
            expect(await destination.readAsBytes(), bytes);
          case _Entry.check || _Entry.directory || _Entry.delete:
            expect(outcome.value, isNull);
        }
        expect(adapter.closes, 1);
        expect(adapter.forced, isTrue);
        expect(
          native.calls,
          entry == _Entry.upload ? 3 : (entry == _Entry.download ? 2 : 1),
        );
        expect(await source.readAsBytes(), bytes);
      },
    );
  }

  test(
    'a failed upload keeps the borrowed file until upload and native cleanup end',
    () async {
      final native = _HeldCall(holdUpload: true);
      final adapter = _Adapter(native.start);
      _retire(native, adapter);
      final ops = WebDavComicBackupOps(
        createClient: (received) =>
            received.endpoint.createClient(adapter: adapter),
      );
      var sourceReleased = false;
      final result = _Observed(() async {
        try {
          await ops.uploadFile(config, source.path, remote);
        } finally {
          await source.delete();
          sourceReleased = true;
        }
      }());
      final options = await native.started.future;
      expect(options.method, 'PUT');
      expect(await native.upload!.moveNext(), isTrue);
      expect(native.upload!.current, bytes);
      native.headers.completeError(StateError('upload response failed'));
      await native.cancelled.future;
      await adapter.closed.future;
      expect(await source.exists(), isTrue);
      expect(sourceReleased, isFalse);
      await native.body.close();
      native.finished.complete();
      await pumpEventQueue();
      expect(
        result.settled,
        isFalse,
        reason: 'native exit does not skip in-flight upload cancellation',
      );
      expect(sourceReleased, isFalse);
      native.releaseUpload.complete();
      final outcome = await result.done;
      expect(outcome.error, isA<DioException>());
      expect(native.uploadCancelled, isTrue);
      expect(sourceReleased, isTrue);
      expect(await source.exists(), isFalse);
    },
  );

  for (final requestFails in [false, true]) {
    test(
      'request and both client/native cleanup errors survive; request fails=$requestFails',
      () async {
        final native = _HeldCall();
        final closeError = StateError('SDK client close failed');
        final closeStack = StackTrace.fromString('SDK close stack');
        final nativeError = StateError('native sender release failed');
        final nativeStack = StackTrace.fromString('native release stack');
        final adapter = _Adapter(
          native.start,
          closeError: closeError,
          closeStack: closeStack,
        );
        _retire(native, adapter);
        final ops = WebDavComicBackupOps(
          createClient: (received) =>
              received.endpoint.createClient(adapter: adapter),
        );
        final result = _Observed(ops.deleteFile(config, remote));
        final options = await native.started.future;
        final cause = StateError('delete failed');
        final causeStack = StackTrace.fromString('delete request stack');
        final sdkFailure = DioException(
          requestOptions: options,
          error: cause,
          stackTrace: causeStack,
        );
        if (requestFails) {
          native.headers.completeError(sdkFailure, causeStack);
          await adapter.closed.future;
          await pumpEventQueue();
          expect(
            result.settled,
            isFalse,
            reason: 'a throwing close must still drain',
          );
        } else {
          native.respond(204, const []);
        }
        await native.body.close();
        native.finished.completeError(
          RHttpCleanupFailure([
            (
              stage: 'release upload sender',
              error: nativeError,
              stack: nativeStack,
            ),
          ]),
        );
        final outcome = await result.done;
        expect(outcome.error, isA<WebDavClientCleanupFailure>());
        final failure = outcome.error! as WebDavClientCleanupFailure;
        if (requestFails) {
          expect(failure.cause, same(sdkFailure));
          expect(
            failure.cause,
            isA<DioException>()
                .having((error) => error.error, 'request cause', same(cause))
                .having(
                  (error) => error.stackTrace.toString(),
                  'request stack',
                  causeStack.toString(),
                ),
          );
          expect(failure.stackTrace, isNotNull);
        } else {
          expect(failure.cause, isNull);
          expect(failure.stackTrace, isNull);
        }
        expect(failure.failures, [
          (stage: 'close WebDAV client', error: closeError, stack: closeStack),
          (
            stage: 'release upload sender',
            error: nativeError,
            stack: nativeStack,
          ),
        ]);
        expect(adapter.closes, 1);
      },
    );
  }

  test(
    'two operations close only their own client and native request',
    () async {
      final natives = [_HeldCall(), _HeldCall()];
      final adapters = [for (final native in natives) _Adapter(native.start)];
      for (var i = 0; i < natives.length; i++) {
        _retire(natives[i], adapters[i]);
      }
      var next = 0;
      final ops = WebDavComicBackupOps(
        createClient: (received) =>
            received.endpoint.createClient(adapter: adapters[next++]),
      );
      final first = _Observed(ops.deleteFile(config, '/Backups/first.cbz'));
      final second = _Observed(ops.deleteFile(config, '/Backups/second.cbz'));
      expect(
        (await natives[0].started.future).uri.path,
        '/DavRoot/Backups/first.cbz',
      );
      expect(
        (await natives[1].started.future).uri.path,
        '/DavRoot/Backups/second.cbz',
      );
      natives[0].headers.completeError(StateError('first failed'));
      await adapters[0].closed.future;
      expect(adapters.map((adapter) => adapter.closes), [1, 0]);
      expect(natives[1].cancelled.isCompleted, isFalse);
      await natives[0].body.close();
      natives[0].finished.complete();
      expect((await first.done).error, isA<DioException>());
      expect(second.settled, isFalse);
      natives[1].respond(204, const []);
      await natives[1].body.close();
      natives[1].finished.complete();
      expect((await second.done).error, isNull);
      expect(adapters.map((adapter) => adapter.closes), [1, 1]);
      expect(next, 2);
    },
  );

  test(
    'missing upload source still retires the created client without dispatch',
    () async {
      final native = _HeldCall();
      final adapter = _Adapter(native.start);
      final ops = WebDavComicBackupOps(
        createClient: (received) =>
            received.endpoint.createClient(adapter: adapter),
      );
      await expectLater(
        ops.uploadFile(config, '${temporary.path}/missing.cbz', remote),
        throwsA(isA<FileSystemException>()),
      );
      expect(adapter.closes, 1);
      expect(native.calls, 0);
      await adapter.waitForIdle();
    },
  );
}

enum _Entry { check, list, exists, directory, upload, download, delete }

Future<Object?> _invoke(
  _Entry entry,
  WebDavComicBackupOps ops,
  BackupConfig config,
  String source,
  String destination,
  String remote,
) async {
  switch (entry) {
    case _Entry.check:
      await ops.test(config);
    case _Entry.list:
      return ops.list(config);
    case _Entry.exists:
      return ops.exists(config, remote);
    case _Entry.directory:
      await ops.ensureDirectory(config);
    case _Entry.upload:
      await ops.uploadFile(config, source, remote);
    case _Entry.download:
      await ops.downloadFile(config, remote, destination);
    case _Entry.delete:
      await ops.deleteFile(config, remote);
  }
  return null;
}

void _expectRequest(_Entry entry, RequestOptions options) {
  expect(options.method, switch (entry) {
    _Entry.check || _Entry.list || _Entry.exists => 'PROPFIND',
    _Entry.directory => 'MKCOL',
    _Entry.upload => 'PUT',
    _Entry.download => 'GET',
    _Entry.delete => 'DELETE',
  });
  expect(options.uri.path, switch (entry) {
    _Entry.check ||
    _Entry.list ||
    _Entry.exists ||
    _Entry.directory => '/DavRoot/Backups/',
    _ => '/DavRoot/Backups/%E4%B8%AD%E6%96%87.cbz',
  });
}

typedef _Outcome = ({Object? value, Object? error, StackTrace? stack});

class _Observed {
  _Observed(Future<Object?> operation) {
    done = operation.then<_Outcome>(
      (value) {
        settled = true;
        return (value: value, error: null, stack: null);
      },
      onError: (Object error, StackTrace stack) {
        settled = true;
        return (value: null, error: error, stack: stack);
      },
    );
  }
  bool settled = false;
  late final Future<_Outcome> done;
}

class _Adapter extends RHttpAdapter {
  _Adapter(RHttpStreamCallFactory start, {this.closeError, this.closeStack})
    : super(startStreamCall: start);
  final Object? closeError;
  final StackTrace? closeStack;
  final closed = Completer<void>();
  int closes = 0;
  bool forced = false;

  @override
  Future<rhttp.ClientSettings> get settings async => const rhttp.ClientSettings(
    proxySettings: rhttp.ProxySettings.noProxy(),
    throwOnStatusCode: false,
  );

  @override
  void close({bool force = false}) {
    closes++;
    forced = force;
    super.close(force: force);
    if (!closed.isCompleted) closed.complete();
    if (closeError != null) Error.throwWithStackTrace(closeError!, closeStack!);
  }
}

class _HeldCall {
  _HeldCall({this.holdUpload = false});
  final bool holdUpload;
  final started = Completer<RequestOptions>();
  final headers =
      Completer<({int statusCode, Map<String, List<String>> headers})>();
  final body = StreamController<Uint8List>();
  final finished = Completer<void>();
  final cancelled = Completer<void>();
  final releaseUpload = Completer<void>();
  StreamIterator<Uint8List>? upload;
  final uploadBytes = <int>[];
  bool uploadCancelled = false;
  bool streaming = false;
  int calls = 0;

  Future<RHttpStreamCall> start(
    RequestOptions options,
    rhttp.ClientSettings settings,
    Stream<Uint8List>? source,
  ) async {
    calls++;
    // The real SDK negotiates OPTIONS before streaming PUT/GET and creates a
    // PUT's parent via MKCOL. Complete those requests, then hold the transfer.
    if (options.method == 'OPTIONS') streaming = true;
    if (options.method == 'OPTIONS' ||
        (streaming && options.method == 'MKCOL')) {
      return RHttpStreamCall(
        response: Future.value((
          statusCode: options.method == 'MKCOL' ? 201 : 200,
          headers: <String, List<String>>{},
        )),
        body: const Stream.empty(),
        finished: Future.value(),
        cancel: () async {},
      );
    }
    if (source != null) {
      if (holdUpload) {
        upload = StreamIterator(source);
      } else {
        await for (final chunk in source) {
          uploadBytes.addAll(chunk);
        }
      }
    }
    started.complete(options);
    return RHttpStreamCall(
      response: headers.future,
      body: body.stream,
      finished: finished.future,
      cancel: () async {
        if (!cancelled.isCompleted) cancelled.complete();
        if (holdUpload) {
          await releaseUpload.future;
          await upload?.cancel();
          uploadCancelled = true;
        }
      },
    );
  }

  void respond(int status, List<int> bytes) {
    headers.complete((statusCode: status, headers: <String, List<String>>{}));
    if (bytes.isNotEmpty) body.add(Uint8List.fromList(bytes));
  }

  void release() {
    if (!releaseUpload.isCompleted) releaseUpload.complete();
    if (!headers.isCompleted) {
      headers.completeError(StateError('fixture disposed'));
    }
    if (!finished.isCompleted) finished.complete();
    unawaited(body.close());
  }
}

void _retire(_HeldCall native, _Adapter adapter) {
  addTearDown(() async {
    native.release();
    await adapter.waitForIdle().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  });
}

const _directoryXml = '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/DavRoot/Backups/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/DavRoot/Backups/folder/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/DavRoot/Backups/%E4%B8%AD%E6%96%87.cbz</d:href><d:propstat><d:prop>
    <d:resourcetype/><d:getcontentlength>7</d:getcontentlength>
    <d:getlastmodified>Sun, 04 Oct 2026 01:02:03 GMT</d:getlastmodified>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/DavRoot/Backups/unknown.cbz</d:href><d:propstat><d:prop>
    <d:resourcetype/>
  </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''';
