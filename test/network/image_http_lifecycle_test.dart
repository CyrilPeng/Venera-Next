import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/image_http_client.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/shared_image_requests.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    App.version = 'image-http-test';
    if (Platform.isWindows) await rhttp.Rhttp.init();
  });

  test(
    'consumer cancel after yielding an image still joins native cleanup',
    () async {
      final adapter = _CleanupAdapter();
      final client = ImageHttpClient(Dio()..httpClientAdapter = adapter);
      final received = Completer<void>();
      final source = StreamController<int>();
      final listener = client
          .run((_) => source.stream)
          .listen((_) => received.complete());
      source.add(1);
      await received.future;
      var cancelled = false;
      final cancelling = listener.cancel().then((_) => cancelled = true);
      await adapter.waiting.future;
      expect(adapter.closes, 1);
      expect(adapter.forced, isTrue);
      await pumpEventQueue();
      expect(cancelled, isFalse);
      adapter.release.complete();
      await cancelling;
      await client.close();
      expect(adapter.closes, 1);
      await source.close();
    },
  );

  test(
    'business error and both close failures remain in one typed error',
    () async {
      final original = StateError('response callback failed');
      final close = StateError('close failed');
      final drain = StateError('native drain failed');
      final adapter = _CleanupAdapter(closeError: close, drainError: drain)
        ..release.complete();
      final client = ImageHttpClient(Dio()..httpClientAdapter = adapter);
      final result = client.run((_) => Stream<void>.error(original)).toList();
      await expectLater(
        result,
        throwsA(
          isA<ImageHttpCleanupFailure>()
              .having(
                (error) => error.cause,
                'original failure',
                same(original),
              )
              .having(
                (error) =>
                    error.failures.map((failure) => failure.error).toList(),
                'all cleanup failures',
                [same(close), same(drain)],
              ),
        ),
      );
      expect(adapter.waiting.isCompleted, isTrue);
      await expectLater(
        client.close(),
        throwsA(isA<ImageHttpCleanupFailure>()),
      );
      expect(adapter.closes, 1);
    },
  );

  group('production image transport', () {
    late Directory directory;
    late CacheManager cache;
    CacheManager? previousCache;
    late bool previousInitialized;
    Object? previousProxy;
    final uploads = <_Upload>[];
    final servers = <_ImagePeer>[];
    setUp(() async {
      directory = Directory.systemTemp.createTempSync('image-http-ownership-');
      previousCache = CacheManager.instance;
      cache = CacheManager.open(
        dataPath: directory.path,
        cacheRoot: directory.path,
      );
      CacheManager.instance = cache;
      previousInitialized = App.isInitialized;
      previousProxy = appdata.settings['proxy'];
      App.isInitialized = false;
      appdata.settings['proxy'] = 'direct';
    });
    tearDown(() async {
      for (final upload in uploads) {
        if (!upload.release.isCompleted) upload.release.complete();
      }
      try {
        await ImageDownloader.cancelAllLoadingImages();
      } catch (_) {}
      ImageDownloader.debugResetSourceImageLoading();
      for (final server in servers) {
        await server.close();
      }
      for (final upload in uploads) {
        unawaited(upload.input.close());
      }
      uploads.clear();
      servers.clear();
      CacheManager.instance = previousCache;
      await cache.dispose();
      App.isInitialized = previousInitialized;
      appdata.settings['proxy'] = previousProxy;
      directory.deleteSync(recursive: true);
    });

    for (final entry in ['thumbnail', 'comic', 'unwrapped']) {
      test(
        '$entry exit preparation waits for native upload release before config disposal',
        () async {
          final upload = _Upload();
          uploads.add(upload);
          final server = await _ImagePeer.start();
          servers.add(server);
          final reference = _Callback(
            (_) => throw StateError('Cancelled callback invoked'),
          );
          Map<String, dynamic> config() => {
            'url': server.url,
            'method': 'POST',
            'data': upload.input.stream,
            'unused': reference,
          };
          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (_, _) => config(),
            comicImageLoadingConfig: (_, _, _, _) => config(),
          );
          final stream = switch (entry) {
            'thumbnail' => ImageDownloader.loadThumbnail(server.url, 'source'),
            'comic' => ImageDownloader.loadComicImage(
              server.url,
              'source',
              'comic',
              'chapter',
            ),
            _ => ImageDownloader.loadComicImageUnwrapped(
              server.url,
              'source',
              'comic',
              'chapter',
            ),
          };
          final listener = stream.listen((event) {
            expect(event.imageBytes, isNull);
          });
          upload.input.add(Uint8List(1024 * 1024));
          await server.requested.future.timeout(const Duration(seconds: 10));
          var prepared = false;
          final preparing = ImageDownloader.prepareForExit().then((release) {
            prepared = true;
            return release;
          });
          await upload.cancelling.future.timeout(const Duration(seconds: 10));
          await pumpEventQueue();
          expect(prepared, isFalse);
          expect(reference.releases, 0);
          upload.release.complete();
          final release = await preparing.timeout(const Duration(seconds: 10));
          release();
          await listener.cancel();
          expect(reference.releases, 1);
          await server.disconnected.future.timeout(const Duration(seconds: 10));
          final key = entry == 'thumbnail'
              ? '${server.url}@source'
              : '${server.url}@source@comic@chapter';
          expect(await cache.findCache(key), isNull);
        },
      );
    }

    test(
      'retry starts only after previous native upload cleanup finishes',
      () async {
        final upload = _Upload();
        uploads.add(upload);
        final server = await _ImagePeer.start(
          firstStatus: 503,
          subsequentStatus: 200,
        );
        servers.add(server);
        final retry = _Callback((_) => <String, dynamic>{'url': server.url});
        ImageDownloader.configureSourceImageLoading(
          comicImageLoadingConfig: (_, _, _, _) => {
            'url': server.url,
            'method': 'POST',
            'data': upload.input.stream,
            'onLoadFailed': retry,
          },
        );
        final result = ImageDownloader.loadComicImage(
          server.url,
          'source',
          'comic',
          'chapter',
        ).toList();
        upload.input.add(Uint8List(1024 * 1024));
        await upload.cancelling.future.timeout(const Duration(seconds: 10));
        await pumpEventQueue();
        expect(retry.calls, 0);
        expect(retry.releases, 0);
        expect(server.requests, 1);
        upload.release.complete();
        final images = await result.timeout(const Duration(seconds: 10));
        expect(images.last.imageBytes, [1, 2, 3]);
        expect(server.requests, 2);
        expect(retry.calls, 1);
        expect(retry.releases, 1);
      },
    );

    test(
      'native cleanup failure blocks fallback and survives exit cancellation',
      () async {
        final failure = StateError('upload release failed');
        final upload = _Upload();
        uploads.add(upload);
        final server = await _ImagePeer.start();
        servers.add(server);
        final retry = _Callback((_) => <String, dynamic>{'url': server.url});
        ImageDownloader.configureSourceImageLoading(
          comicImageLoadingConfig: (_, _, _, _) => {
            'url': server.url,
            'method': 'POST',
            'data': upload.input.stream,
            'onLoadFailed': retry,
          },
        );
        final listener = ImageDownloader.loadComicImage(
          server.url,
          'source',
          'comic',
          'chapter',
        ).listen((_) {});
        upload.input.add(Uint8List(1024 * 1024));
        await server.requested.future.timeout(const Duration(seconds: 10));
        final preparing = ImageDownloader.prepareForExit();
        final failed = expectLater(
          preparing,
          throwsA(
            isA<SharedImageRequestFailure>().having(
              (error) => error.failures.single.error,
              'typed transport error',
              isA<ImageHttpCleanupFailure>().having(
                (error) => error.failures.map((failure) => failure.error),
                'original release error',
                contains(same(failure)),
              ),
            ),
          ),
        );
        await upload.cancelling.future.timeout(const Duration(seconds: 10));
        upload.release.completeError(failure);
        await failed.timeout(const Duration(seconds: 10));
        await listener.cancel();
        expect(retry.calls, 0);
        expect(retry.releases, 1);
        expect(server.requests, 1);
      },
    );
  }, skip: !Platform.isWindows);
}

class _CleanupAdapter extends RHttpAdapter {
  _CleanupAdapter({this.closeError, this.drainError});
  final Object? closeError;
  final Object? drainError;
  final waiting = Completer<void>();
  final release = Completer<void>();
  int closes = 0;
  bool forced = false;
  @override
  void close({bool force = false}) {
    closes++;
    forced = force;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<void> waitForIdle() async {
    waiting.complete();
    await release.future;
    if (drainError != null) throw drainError!;
  }
}

class _Callback extends JSInvokable {
  _Callback(this.callback);
  final dynamic Function(List args) callback;
  int calls = 0;
  int releases = 0;
  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    calls++;
    return callback(args);
  }

  @override
  void destroy() {
    releases++;
  }
}

class _Upload {
  _Upload() {
    input = StreamController<Uint8List>(
      onCancel: () {
        cancelling.complete();
        return release.future;
      },
    );
  }
  final cancelling = Completer<void>();
  final release = Completer<void>();
  late final StreamController<Uint8List> input;
}

class _ImagePeer {
  _ImagePeer(this.server, this.firstStatus, this.subsequentStatus) {
    server.listen((socket) {
      sockets.add(socket);
      var accepted = false;
      socket.listen(
        (_) {
          if (accepted) return;
          accepted = true;
          requests++;
          if (!requested.isCompleted) requested.complete();
          final status = requests == 1 ? firstStatus : subsequentStatus;
          if (status != null) {
            socket.write(
              'HTTP/1.1 $status Result\r\nContent-Length: 3\r\nConnection: close\r\n\r\n',
            );
            socket.add([1, 2, 3]);
            unawaited(socket.flush().then((_) => socket.close()));
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
  final int? firstStatus;
  final int? subsequentStatus;
  final sockets = <Socket>[];
  final requested = Completer<void>();
  final disconnected = Completer<void>();
  int requests = 0;
  String get url => 'http://127.0.0.1:${server.port}';
  static Future<_ImagePeer> start({
    int? firstStatus,
    int? subsequentStatus,
  }) async => _ImagePeer(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    firstStatus,
    subsequentStatus,
  );
  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}
