import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

class _CancelOnInspectMap extends MapBase<String, dynamic> {
  _CancelOnInspectMap(this.valuesByKey, this.cancel);

  final Map<String, dynamic> valuesByKey;
  final void Function() cancel;
  bool inspected = false;

  @override
  Iterable<MapEntry<String, dynamic>> get entries {
    if (!inspected) {
      inspected = true;
      cancel();
    }
    return valuesByKey.entries;
  }

  @override
  dynamic operator [](Object? key) => valuesByKey[key];
  @override
  void operator []=(String key, dynamic value) => valuesByKey[key] = value;
  @override
  Iterable<String> get keys => valuesByKey.keys;
  @override
  void clear() => valuesByKey.clear();
  @override
  dynamic remove(Object? key) => valuesByKey.remove(key);
}

bool _quickJsAvailable() {
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    return true;
  } catch (_) {
    return false;
  }
}

class _Callback extends JSInvokable {
  _Callback(this.callback, {this.cleanupError});

  final dynamic Function(List args) callback;
  final Object? cleanupError;
  int calls = 0;
  int releases = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    if (releases != 0) throw StateError('Callback used after release');
    calls++;
    return callback(args);
  }

  @override
  void destroy() {
    releases++;
    if (cleanupError case final error?) throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeAvailable = _quickJsAvailable();
  setUpAll(() async {
    if (Platform.isWindows || Platform.isLinux) await rhttp.Rhttp.init();
  });

  late Directory directory;
  late CacheManager cache;
  late HttpServer server;
  late bool previousInitialized;
  Object? previousProxy;
  CacheManager? previousCache;
  final requests = <String>[];

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('image-config-owner-');
    previousCache = CacheManager.instance;
    previousInitialized = App.isInitialized;
    previousProxy = appdata.settings['proxy'];
    App.isInitialized = false;
    appdata.settings['proxy'] = 'direct';
    cache = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
    );
    CacheManager.instance = cache;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests.add(request.uri.path);
      request.response.statusCode = request.uri.path == '/fail'
          ? HttpStatus.serviceUnavailable
          : HttpStatus.ok;
      request.response.add([1, 2, 3]);
      unawaited(request.response.close());
    });
  });

  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.configureSourceImageLoading();
    CacheManager.instance = previousCache;
    App.isInitialized = previousInitialized;
    appdata.settings['proxy'] = previousProxy;
    await server.close(force: true);
    await cache.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<List<ImageDownloadProgress>> comic(Map<String, dynamic> config) {
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (_, _, _, _) => config,
    );
    return ImageDownloader.loadComicImage(
      'image',
      'source',
      'comic',
      'episode',
    ).toList();
  }

  test(
    'cancellation after configuration delivery releases refs before first request',
    () async {
      final response = _Callback(
        (_) => throw StateError('Unexpected response'),
      );
      final retry = _Callback((_) => throw StateError('Unexpected retry'));
      late _CancelOnInspectMap config;
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, _, _, _) {
          final scope = RequestScope.current!;
          // Cancel on the first inspection of the delivered map. The resolver's
          // cancellation race has already handed ownership to the downloader.
          return config = _CancelOnInspectMap({
            'url': url('/ok'),
            'onResponse': response,
            'onLoadFailed': retry,
          }, scope.cancel);
        },
      );
      await expectLater(
        ImageDownloader.loadComicImage(
          'image',
          'source',
          'comic',
          'episode',
        ).toList(),
        throwsA(isA<RequestCancelled>()),
      );
      expect(config.inspected, isTrue);
      expect([response.calls, retry.calls], [0, 0]);
      expect([response.releases, retry.releases], [1, 1]);
      expect(requests, isEmpty);
    },
  );

  test(
    'cancellation drains an active retry callback and frees its late config',
    () async {
      final started = Completer<void>();
      final nextConfig = Completer<Map<String, dynamic>>();
      final oldResponse = _Callback(
        (_) => throw StateError('Unexpected response'),
      );
      final oldRetry = _Callback((_) {
        started.complete();
        return nextConfig.future;
      });
      final newResponse = _Callback(
        (_) => throw StateError('Late response invoked'),
      );
      final newRetry = _Callback((_) => throw StateError('Late retry invoked'));
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, _, _, _) => {
          'url': url('/fail'),
          'onResponse': oldResponse,
          'onLoadFailed': oldRetry,
        },
      );
      final errors = <Object>[];
      final subscription =
          ImageDownloader.loadComicImage(
            'image',
            'source',
            'comic',
            'episode',
          ).listen(
            (_) => fail('Cancelled image must not be delivered'),
            onError: errors.add,
          );
      await started.future;
      var cancelled = false;
      final cancelling = subscription.cancel();
      unawaited(cancelling.then((_) => cancelled = true));
      await pumpEventQueue();
      expect(cancelled, isFalse);
      expect([oldResponse.releases, oldRetry.releases], [0, 0]);
      nextConfig.complete({
        'url': url('/ok'),
        'onResponse': newResponse,
        'onLoadFailed': newRetry,
      });
      await cancelling;
      expect(
        [oldResponse.calls, oldRetry.calls, newResponse.calls, newRetry.calls],
        [0, 1, 0, 0],
      );
      expect(
        [
          oldResponse.releases,
          oldRetry.releases,
          newResponse.releases,
          newRetry.releases,
        ],
        [1, 1, 1, 1],
      );
      expect(errors, isEmpty);
      expect(requests, ['/fail']);
      expect(await cache.findCache('image@source@comic@episode'), isNull);
    },
  );

  for (final callbackKind in ['response', 'retry']) {
    for (final cleanupFails in [false, true]) {
      test(
        'cancelled $callbackKind rejection releases late refs and retains config aliases; cleanupFails=$cleanupFails',
        () async {
          final started = Completer<void>();
          final rejectedResult = Completer<dynamic>();
          final orphanCleanup = StateError('late orphan cleanup failed');
          late _Callback response;
          late _Callback retry;
          final orphan = _Callback(
            (_) => null,
            cleanupError: cleanupFails ? orphanCleanup : null,
          );
          final releaseOrder = <String>[];
          final inspector = _InspectingReference(() {
            // The rejected graph only borrows these current configuration refs.
            // They must remain live until the final configuration cleanup.
            expect(response.releases, 0);
            expect(retry.releases, 0);
            releaseOrder.add('orphan');
          });
          response = _Callback((_) {
            if (callbackKind != 'response') {
              throw StateError('Unexpected response');
            }
            started.complete();
            return rejectedResult.future;
          });
          retry = _Callback((_) {
            if (callbackKind != 'retry') throw StateError('Unexpected retry');
            started.complete();
            return rejectedResult.future;
          });
          final rejected = <String, dynamic>{
            'borrowed': [response, retry, response],
            'new': [inspector, orphan, orphan],
          };
          rejected['self'] = rejected;
          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig: (_, _, _, _) => {
              'url': url(callbackKind == 'response' ? '/ok' : '/fail'),
              'onResponse': response,
              'onLoadFailed': retry,
            },
          );
          final events = <ImageDownloadProgress>[];
          final errors = <Object>[];
          final subscription = ImageDownloader.loadComicImage(
            'cancelled-callback',
            'source',
            'comic',
            'episode',
          ).listen(events.add, onError: errors.add);
          await started.future;
          final cancelling = subscription.cancel();
          final observed = cleanupFails
              ? expectLater(
                  cancelling,
                  throwsA(
                    isA<ImageLoadingConfigFailure>()
                        .having(
                          (failure) => failure.cause,
                          'rejected graph',
                          same(rejected),
                        )
                        .having(
                          (failure) => failure.cleanupFailure.failures.map(
                            (entry) => entry.error,
                          ),
                          'late cleanup failure',
                          [same(orphanCleanup)],
                        ),
                  ),
                )
              : expectLater(cancelling, completes);
          await pumpEventQueue();
          rejectedResult.completeError(rejected);
          await observed;
          expect(
            [response.releases, retry.releases, orphan.releases],
            [1, 1, 1],
          );
          expect(releaseOrder, ['orphan']);
          expect(events.where((event) => event.imageBytes != null), isEmpty);
          expect(errors, isEmpty);
          expect(requests, [callbackKind == 'response' ? '/ok' : '/fail']);
          expect(
            await cache.findCache('cancelled-callback@source@comic@episode'),
            isNull,
          );
        },
      );
    }
  }

  for (final asynchronous in [false, true]) {
    test(
      'native QuickJS reuses JS functions across retries; async=$asynchronous',
      () async {
        final engine = JsEngine.create(
          loadInitScript: () async => Uint8List(0),
        );
        await engine.init();
        try {
          final config = Map<String, dynamic>.from(
            await engine.runOwnedCode('''
          (() => {
            globalThis.retryCalls = 0;
            globalThis.responseCalls = 0;
            ${asynchronous ? 'async' : ''} function response(bytes) {
              globalThis.responseCalls++;
              return new Uint8Array([8, 7, 6]).buffer;
            }
            ${asynchronous ? 'async' : ''} function retry() {
              globalThis.retryCalls++;
              return {
                url: globalThis.retryCalls < 3 ? ${jsonEncode(url('/fail'))} : ${jsonEncode(url('/ok'))},
                onResponse: response,
                onLoadFailed: retry
              };
            }
            return {url: ${jsonEncode(url('/fail'))}, onResponse: response, onLoadFailed: retry};
          })()
        '''),
          );
          expect(engine.debugOwnedReferenceCount, 2);
          final events = await comic(config);
          expect(events.last.imageBytes, [8, 7, 6]);
          expect(engine.runCode('globalThis.retryCalls'), 3);
          expect(engine.runCode('globalThis.responseCalls'), 1);
          expect(engine.debugOwnedReferenceCount, 0);
          expect(requests, ['/fail', '/fail', '/fail', '/ok']);
        } finally {
          engine.dispose();
        }
      },
      skip: nativeAvailable ? false : 'QuickJS native library unavailable',
    );
  }

  test(
    'invalid callback cleanup failure is not hidden by a successful fallback',
    () async {
      final cleanupError = StateError('discarded result cleanup failed');
      final orphan = _Callback((_) => null, cleanupError: cleanupError);
      final response = _Callback(
        (_) => {
          'invalid': [orphan],
        },
      );
      final retry = _Callback((_) => {'url': url('/ok')});
      await expectLater(
        comic({
          'url': url('/ok'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(
          isA<ImageLoadingConfigFailure>()
              .having(
                (failure) => failure.cause,
                'invalid result',
                isA<OperationFailure>().having(
                  (error) => error.message,
                  'message',
                  'Error: Invalid onResponse result.',
                ),
              )
              .having(
                (failure) =>
                    failure.cleanupFailure.failures.map((item) => item.error),
                'cleanup error',
                [same(cleanupError)],
              ),
        ),
      );
      expect([response.calls, retry.calls], [1, 0]);
      expect([response.releases, retry.releases, orphan.releases], [1, 1, 1]);
      expect(requests, ['/ok']);
    },
  );

  test(
    'successful download releases all callbacks once, including unused refs',
    () async {
      final response = _Callback((args) => <int>[9, 8, 7]);
      final retry = _Callback((_) => throw StateError('Unexpected retry'));
      final unused = _Callback(
        (_) => throw StateError('Unexpected nested callback'),
      );
      final config = <String, dynamic>{
        'url': url('/ok'),
        'onResponse': response,
        'onLoadFailed': retry,
        'extra': [unused, response, retry, unused],
      };
      config['cycle'] = config;
      final events = await comic(config);
      expect(events.last.imageBytes, [9, 8, 7]);
      expect(response.calls, 1);
      expect(retry.calls, 0);
      expect(unused.calls, 0);
      expect([response.releases, retry.releases, unused.releases], [1, 1, 1]);
      expect(requests, ['/ok']);
    },
  );

  test(
    'network failure releases response callback even when never invoked',
    () async {
      final response = _Callback(
        (_) => throw StateError('Unexpected response'),
      );
      final retry = _Callback((_) => null);
      await expectLater(
        comic({
          'url': url('/fail'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(isA<DioException>()),
      );
      expect(response.calls, 0);
      expect(retry.calls, 1);
      expect([response.releases, retry.releases], [1, 1]);
      expect(requests, ['/fail']);
    },
  );

  test(
    'invalid headers before the request still release every configuration ref',
    () async {
      final response = _Callback(
        (_) => throw StateError('Unexpected response'),
      );
      final retry = _Callback((_) => null);
      await expectLater(
        comic({
          'url': url('/ok'),
          'headers': 'invalid headers',
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(anything),
      );
      expect([response.releases, retry.releases], [1, 1]);
      expect(response.calls, 0);
      expect(requests, isEmpty);
    },
  );

  test(
    'retry retires unused old callbacks and releases the successful new config',
    () async {
      final oldResponse = _Callback(
        (_) => throw StateError('Unexpected old response'),
      );
      final newResponse = _Callback((_) => <int>[7, 8]);
      final newRetry = _Callback(
        (_) => throw StateError('Unexpected second retry'),
      );
      final oldRetry = _Callback(
        (_) => {
          'url': url('/ok'),
          'onResponse': newResponse,
          'onLoadFailed': newRetry,
        },
      );
      final events = await comic({
        'url': url('/fail'),
        'onResponse': oldResponse,
        'onLoadFailed': oldRetry,
      });
      expect(events.last.imageBytes, [7, 8]);
      expect(
        [oldResponse.calls, oldRetry.calls, newResponse.calls, newRetry.calls],
        [0, 1, 1, 0],
      );
      expect(
        [
          oldResponse.releases,
          oldRetry.releases,
          newResponse.releases,
          newRetry.releases,
        ],
        [1, 1, 1, 1],
      );
      expect(requests, ['/fail', '/ok']);
    },
  );

  test(
    'the same Dart response callback survives a transfer into the retry config',
    () async {
      final response = _Callback((_) => <int>[4, 5]);
      final retry = _Callback((_) {
        expect(response.releases, 0);
        return {'url': url('/ok'), 'onResponse': response};
      });
      final events = await comic({
        'url': url('/fail'),
        'onResponse': response,
        'onLoadFailed': retry,
      });
      expect(events.last.imageBytes, [4, 5]);
      expect([response.calls, retry.calls], [1, 1]);
      expect([response.releases, retry.releases], [1, 1]);
    },
  );

  test(
    'response and retry aliases can be reused without early or duplicate free',
    () async {
      late _Callback shared;
      shared = _Callback((args) {
        if (args.isEmpty) {
          return {
            'url': url('/ok'),
            'onResponse': shared,
            'onLoadFailed': shared,
            'nested': [shared],
          };
        }
        return <int>[6, 7];
      });
      final events = await comic({
        'url': url('/fail'),
        'onResponse': shared,
        'onLoadFailed': shared,
      });
      expect(events.last.imageBytes, [6, 7]);
      expect(shared.calls, 2);
      expect(shared.releases, 1);
      expect(requests, ['/fail', '/ok']);
    },
  );

  test(
    'invalid response results release nested refs while retaining owned aliases',
    () async {
      final orphan = _Callback(
        (_) => throw StateError('Unexpected orphan call'),
      );
      late _Callback response;
      response = _Callback(
        (_) => {
          'nested': [orphan, response, orphan],
        },
      );
      final retry = _Callback((_) => null);
      await expectLater(
        comic({
          'url': url('/ok'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(
          isA<OperationFailure>()
              .having(
                (error) => error.message,
                'message',
                'Error: Invalid onResponse result.',
              )
              .having((error) => error.stackTrace, 'stack', isNotNull),
        ),
      );
      expect([response.calls, retry.calls, orphan.calls], [1, 1, 0]);
      expect([response.releases, retry.releases, orphan.releases], [1, 1, 1]);
    },
  );

  for (final failure in <Object>[
    const RequestCancelled(),
    UnsupportedError('image operation unavailable'),
    const OperationFailure(
      message: 'source cancelled image processing',
      kind: FailureKind.cancelled,
    ),
    const OperationFailure(
      message: 'source cannot process this image',
      kind: FailureKind.unsupported,
    ),
  ]) {
    test('terminal image failure does not retry: $failure', () async {
      final response = _Callback((_) => throw failure);
      final retry = _Callback((_) => {'url': url('/ok')});
      await expectLater(
        comic({
          'url': url('/ok'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(same(failure)),
      );
      expect(requests, ['/ok']);
      expect([response.calls, retry.calls], [1, 0]);
      expect([response.releases, retry.releases], [1, 1]);
    });
  }

  test(
    'invalid retry results free nested refs and preserve the network failure',
    () async {
      final orphan = _Callback(
        (_) => throw StateError('Unexpected orphan call'),
      );
      final response = _Callback(
        (_) => throw StateError('Unexpected response'),
      );
      late _Callback retry;
      retry = _Callback(
        (_) => <dynamic, dynamic>{
          'nested': [orphan, retry, response, orphan],
          1: 'invalid config key',
        },
      );
      await expectLater(
        comic({
          'url': url('/fail'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(isA<DioException>()),
      );
      expect([response.calls, retry.calls, orphan.calls], [0, 1, 0]);
      expect([response.releases, retry.releases, orphan.releases], [1, 1, 1]);
    },
  );

  test(
    'a download failure and every cleanup failure remain observable',
    () async {
      final first = StateError('response cleanup failed');
      final second = StateError('retry cleanup failed');
      final response = _Callback((_) => <int>[], cleanupError: first);
      final retry = _Callback((_) => null, cleanupError: second);
      await expectLater(
        comic({
          'url': url('/fail'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(
          isA<ImageLoadingConfigFailure>()
              .having(
                (failure) => failure.cause,
                'download cause',
                isA<DioException>(),
              )
              .having(
                (failure) => failure.stackTrace.toString(),
                'download stack',
                isNotEmpty,
              )
              .having(
                (failure) =>
                    failure.cleanupFailure.failures.map((item) => item.error),
                'cleanup causes',
                unorderedEquals([same(first), same(second)]),
              ),
        ),
      );
      expect([response.releases, retry.releases], [1, 1]);
    },
  );

  test(
    'a successful download reports a cleanup-only failure without retrying',
    () async {
      final error = StateError('unused callback cleanup failed');
      final response = _Callback((_) => <int>[3, 2, 1]);
      final retry = _Callback(
        (_) => throw StateError('Unexpected retry'),
        cleanupError: error,
      );
      await expectLater(
        comic({
          'url': url('/ok'),
          'onResponse': response,
          'onLoadFailed': retry,
        }),
        throwsA(
          isA<ImageLoadingConfigCleanupFailure>().having(
            (failure) => failure.failures.map((item) => item.error),
            'cleanup cause',
            [same(error)],
          ),
        ),
      );
      expect([response.calls, retry.calls], [1, 0]);
      expect([response.releases, retry.releases], [1, 1]);
      expect(requests, ['/ok']);
    },
  );

  for (final succeeds in [true, false]) {
    test(
      'thumbnail releases response and unused callbacks; succeeds=$succeeds',
      () async {
        final response = _Callback((_) => <int>[8, 9]);
        final unused = _Callback(
          (_) => throw StateError('Unexpected thumbnail retry'),
        );
        ImageDownloader.configureSourceImageLoading(
          thumbnailLoadingConfig: (_, _) => {
            'url': url(succeeds ? '/ok' : '/fail'),
            'onResponse': response,
            'onLoadFailed': unused,
            'extra': [response, unused],
          },
        );
        final loading = ImageDownloader.loadThumbnail(
          url('/thumbnail'),
          'source',
        ).toList();
        if (succeeds) {
          expect((await loading).last.imageBytes, [8, 9]);
        } else {
          await expectLater(loading, throwsA(isA<DioException>()));
        }
        expect(response.calls, succeeds ? 1 : 0);
        expect(unused.calls, 0);
        expect([response.releases, unused.releases], [1, 1]);
      },
    );
  }

  test(
    'thumbnail cover redirection releases the outer and resolved configs',
    () async {
      final outer = _Callback(
        (_) => throw StateError('Unexpected outer response'),
      );
      final inner = _Callback((_) => <int>[5, 4]);
      final unused = _Callback((_) => throw StateError('Unexpected callback'));
      final resolvedUrls = <String>[];
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (_, imageUrl) {
          resolvedUrls.add(imageUrl);
          return imageUrl.startsWith('cover.')
              ? {
                  'url': 'cover.redirect',
                  'onResponse': outer,
                  'onLoadFailed': unused,
                }
              : {'onResponse': inner};
        },
        thumbnailCover: (_, _) => url('/ok'),
      );
      final events = await ImageDownloader.loadThumbnail(
        'cover.book',
        'source',
        'comic',
      ).toList();
      expect(events.last.imageBytes, [5, 4]);
      expect(resolvedUrls, ['cover.book', url('/ok')]);
      expect([outer.calls, inner.calls, unused.calls], [0, 1, 0]);
      expect([outer.releases, inner.releases, unused.releases], [1, 1, 1]);
      expect(requests, ['/ok']);
    },
  );
}

class _InspectingReference extends JSRef {
  _InspectingReference(this.onRelease);
  final void Function() onRelease;

  @override
  void destroy() => onRelease();
}
