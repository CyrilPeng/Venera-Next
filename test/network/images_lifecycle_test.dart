import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';

void main() {
  late Directory directory;
  late CacheManager cache;
  CacheManager? previous;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('venera-image-lifecycle-');
    previous = CacheManager.instance;
    cache = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
    );
    CacheManager.instance = cache;
  });
  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.configureSourceImageLoading();
    CacheManager.instance = previous;
    await cache.dispose();
    directory.deleteSync(recursive: true);
  });

  test('cached image completes without source resolution or network', () async {
    await cache.writeCache('image@source@comic@chapter', [1, 2, 3]);
    var sourceCalls = 0;
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (a, b, c, d) {
        sourceCalls++;
        throw StateError('Cache hit must not resolve a source');
      },
    );
    final events = await ImageDownloader.loadComicImage(
      'image',
      'source',
      'comic',
      'chapter',
    ).toList();
    expect(events.single.imageBytes, [1, 2, 3]);
    expect(sourceCalls, 0);
  });

  test('last release cancels production source resolution scope', () async {
    final started = Completer<RequestScope>();
    final configuration = Completer<Map<String, dynamic>>();
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (a, b, c, d) {
        started.complete(RequestScope.current!);
        return configuration.future;
      },
    );
    final first = ImageDownloader.loadComicImage(
      'image',
      'source',
      'comic',
      'chapter',
    ).listen((_) {});
    final second = ImageDownloader.loadComicImage(
      'image',
      'source',
      'comic',
      'chapter',
    ).listen((_) {});
    final scope = await started.future;
    await first.cancel();
    expect(scope.isCancelled, false);
    var cancelled = false;
    final cancelling = second.cancel();
    unawaited(cancelling.then((_) => cancelled = true));
    expect(scope.cancelToken.isCancelled, true);
    await pumpEventQueue();
    expect(cancelled, isFalse);
    configuration.complete({'url': 'https://example.invalid/late'});
    await cancelling;
    await pumpEventQueue();
    expect(await cache.findCache('image@source@comic@chapter'), isNull);
  });

  for (final cleanupFails in [false, true]) {
    test(
      'late configuration releases all references; cleanupFails=$cleanupFails',
      () async {
        final configuration = Completer<Map<String, dynamic>>();
        final started = Completer<void>();
        final firstError = StateError('release first');
        final secondError = StateError('release second');
        final response = _UnusedImageCallback(cleanupFails ? firstError : null);
        final retry = _UnusedImageCallback(cleanupFails ? secondError : null);
        final nested = _UnusedImageCallback(null);
        ImageDownloader.configureSourceImageLoading(
          comicImageLoadingConfig: (a, b, c, d) {
            started.complete();
            return configuration.future;
          },
        );
        final subscription = ImageDownloader.loadComicImage(
          'late-image',
          'source',
          'comic',
          'chapter',
        ).listen((_) => fail('cancelled image must not be delivered'));
        await started.future;
        final cancelling = subscription.cancel();
        final checked = cleanupFails
            ? expectLater(
                cancelling,
                throwsA(
                  isA<ImageLoadingConfigCleanupFailure>().having(
                    (failure) => failure.failures.map((item) => item.error),
                    'causes',
                    [firstError, secondError],
                  ),
                ),
              )
            : expectLater(cancelling, completes);
        final config = <String, dynamic>{
          'url': 'https://example.invalid/cancelled',
          'onResponse': response,
          'onLoadFailed': retry,
          'nested': [nested, response, retry],
        };
        config['cycle'] = config;
        configuration.complete(config);
        await checked;
        expect(response.releases, 1);
        expect(retry.releases, 1);
        expect(nested.releases, 1);
        expect(
          await cache.findCache('late-image@source@comic@chapter'),
          isNull,
        );
      },
    );
  }

  test(
    'late source failure completes cancellation without publishing an error',
    () async {
      final configuration = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (a, b, c, d) {
          started.complete();
          return configuration.future;
        },
      );
      final subscription =
          ImageDownloader.loadComicImage(
            'late-failure',
            'source',
            'comic',
            'chapter',
          ).listen(
            (_) => fail('unexpected image'),
            onError: (Object error) => fail('$error'),
          );
      await started.future;
      final cancelling = subscription.cancel();
      await pumpEventQueue();
      configuration.completeError(
        StateError('source failed after cancellation'),
      );
      await cancelling;
      expect(
        await cache.findCache('late-failure@source@comic@chapter'),
        isNull,
      );
    },
  );

  for (final cleanupFails in [false, true]) {
    test(
      'cancelled source rejection releases its graph; cleanupFails=$cleanupFails',
      () async {
        final configuration = Completer<Map<String, dynamic>>();
        final started = Completer<void>();
        final firstError = StateError('rejected first reference cleanup');
        final secondError = StateError('rejected second reference cleanup');
        final first = _UnusedImageCallback(cleanupFails ? firstError : null);
        final second = _UnusedImageCallback(cleanupFails ? secondError : null);
        final rejected = <String, dynamic>{
          'nested': [first, second, first],
        };
        rejected['self'] = rejected;
        ImageDownloader.configureSourceImageLoading(
          comicImageLoadingConfig: (_, _, _, _) {
            started.complete();
            return configuration.future;
          },
        );
        final subscription = ImageDownloader.loadComicImage(
          'late-rejected-graph',
          'source',
          'comic',
          'chapter',
        ).listen((_) => fail('cancelled image must not be delivered'));
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
                        'all cleanup failures',
                        [same(firstError), same(secondError)],
                      ),
                ),
              )
            : expectLater(cancelling, completes);
        await pumpEventQueue();
        configuration.completeError(rejected);
        await observed;
        expect(first.releases, 1);
        expect(second.releases, 1);
      },
    );
  }

  for (final combined in [false, true]) {
    test(
      'cancelled source preserves a late parser cleanup failure; combined=$combined',
      () async {
        final configuration = Completer<Map<String, dynamic>>();
        final started = Completer<void>();
        final cleanup = ImageLoadingConfigCleanupFailure([
          (
            error: StateError('parser reference cleanup'),
            stack: StackTrace.current,
          ),
        ]);
        final Object failure = combined
            ? ImageLoadingConfigFailure(
                cause: StateError('invalid source configuration'),
                stackTrace: StackTrace.current,
                cleanupFailure: cleanup,
              )
            : cleanup;
        ImageDownloader.configureSourceImageLoading(
          comicImageLoadingConfig: (_, _, _, _) {
            started.complete();
            return configuration.future;
          },
        );
        final subscription = ImageDownloader.loadComicImage(
          'late-parser-failure',
          'source',
          'comic',
          'chapter',
        ).listen((_) => fail('cancelled image must not be delivered'));
        await started.future;
        final cancelling = subscription.cancel();
        final observed = expectLater(cancelling, throwsA(same(failure)));
        await pumpEventQueue();
        configuration.completeError(failure);
        await observed;
      },
    );
  }
}

class _UnusedImageCallback extends JSInvokable {
  _UnusedImageCallback(this.error);
  final Object? error;
  var releases = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) =>
      throw StateError('Discarded callbacks must not be invoked');

  @override
  void destroy() {
    releases++;
    final failure = error;
    if (failure != null) throw failure;
  }
}
