import 'dart:async';
import 'dart:io';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/network/shared_image_requests.dart';

class _Reference extends JSInvokable {
  _Reference([this.failure]);

  final Object? failure;
  var releases = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) =>
      throw StateError('Cancelled request must not invoke its callbacks');

  @override
  void destroy() {
    releases++;
    if (failure case final error?) throw error;
  }
}

class _PendingConfiguration {
  _PendingConfiguration([Object? cleanupFailure])
    : reference = _Reference(cleanupFailure);

  final started = Completer<RequestScope>();
  final result = Completer<Map<String, dynamic>>();
  final _Reference reference;

  Future<Map<String, dynamic>> resolve() {
    started.complete(RequestScope.current!);
    return result.future;
  }

  void finish() {
    if (!result.isCompleted) {
      result.complete({
        'url': 'https://example.invalid/must-not-request',
        'unused': reference,
      });
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CacheManager cache;
  CacheManager? previousCache;
  final configurations = <_PendingConfiguration>[];
  final releases = <void Function()>[];

  _PendingConfiguration pending([Object? cleanupFailure]) {
    final value = _PendingConfiguration(cleanupFailure);
    configurations.add(value);
    return value;
  }

  Stream<ImageDownloadProgress> comic(String image) =>
      ImageDownloader.loadComicImage(image, 'source', 'comic', 'chapter');

  Future<void Function()> prepare() async {
    final release = await ImageDownloader.prepareForExit();
    releases.add(release);
    return release;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('image-request-shutdown-');
    previousCache = CacheManager.instance;
    cache = CacheManager.open(
      dataPath: directory.path,
      cacheRoot: directory.path,
    );
    CacheManager.instance = cache;
  });

  tearDown(() async {
    for (final configuration in configurations) {
      configuration.finish();
    }
    try {
      (await ImageDownloader.prepareForExit())();
    } catch (_) {
      // Expected cleanup failures are asserted by the individual tests.
    }
    for (final release in releases) {
      release();
    }
    configurations.clear();
    releases.clear();
    ImageDownloader.configureSourceImageLoading();
    CacheManager.instance = previousCache;
    await cache.dispose();
    directory.deleteSync(recursive: true);
  });

  test(
    'production preparation waits for an ignored retired request after same-key replacement',
    () async {
      final old = pending();
      final current = pending();
      var resolutions = 0;
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, _, _, _) =>
            (++resolutions == 1 ? old : current).resolve(),
      );
      final first = comic(
        'image',
      ).listen((_) => fail('Cancelled image was delivered'));
      final oldScope = await old.started.future;
      first.cancel().ignore();
      expect(oldScope.isCancelled, isTrue);
      comic('image').listen((_) => fail('Cancelled replacement was delivered'));
      final currentScope = await current.started.future;
      expect(resolutions, 2);

      var prepared = false;
      final preparing = prepare();
      preparing.then((_) => prepared = true);
      expect(currentScope.isCancelled, isTrue);
      current.finish();
      await pumpEventQueue();
      expect(current.reference.releases, 1);
      expect(old.reference.releases, 0);
      expect(prepared, isFalse);
      old.finish();
      (await preparing)();
      expect(old.reference.releases, 1);
      expect(await cache.findCache('image@source@comic@chapter'), isNull);
    },
  );

  test(
    'production preparation joins shared, unwrapped and thumbnail requests',
    () async {
      final shared = pending();
      final unwrapped = pending();
      final thumbnail = pending();
      var sharedCalls = 0;
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, key, _, _) {
          if (key == 'shared') {
            sharedCalls++;
            return shared.resolve();
          }
          return unwrapped.resolve();
        },
        thumbnailLoadingConfig: (_, _) => thumbnail.resolve(),
      );
      final first = comic(
        'shared',
      ).listen((_) => fail('Unexpected shared result'));
      final visible = comic(
        'shared',
      ).listen((_) => fail('Unexpected visible result'));
      final sharedScope = await shared.started.future;
      await first.cancel();
      expect(sharedScope.isCancelled, isFalse);
      expect(sharedCalls, 1);
      ImageDownloader.loadComicImageUnwrapped(
        'unwrapped',
        'source',
        'comic',
        'chapter',
      ).listen((_) => fail('Unexpected unwrapped result'));
      ImageDownloader.loadThumbnail(
        'thumbnail',
        'source',
      ).listen((_) => fail('Unexpected thumbnail result'));
      final otherScopes = await Future.wait([
        unwrapped.started.future,
        thumbnail.started.future,
      ]);

      var prepared = false;
      final preparing = prepare();
      preparing.then((_) => prepared = true);
      expect(sharedScope.isCancelled, isTrue);
      expect(otherScopes.every((scope) => scope.isCancelled), isTrue);
      shared.finish();
      unwrapped.finish();
      await pumpEventQueue();
      expect(prepared, isFalse);
      thumbnail.finish();
      (await preparing)();
      await visible.cancel();
      expect(configurations.map((entry) => entry.reference.releases), [
        1,
        1,
        1,
      ]);
      for (final key in [
        'shared@source@comic@chapter',
        'unwrapped@source@comic@chapter',
        'thumbnail@source',
      ]) {
        expect(await cache.findCache(key), isNull);
      }
    },
  );

  test(
    'all production entry points reject work until every preparation is released',
    () async {
      var resolutions = 0;
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, _, _, _) {
          resolutions++;
          throw StateError('Held request reached its resolver');
        },
        thumbnailLoadingConfig: (_, _) {
          resolutions++;
          throw StateError('Held thumbnail reached its resolver');
        },
      );
      final openers = <Stream<ImageDownloadProgress> Function()>[
        () => comic('cached'),
        () => ImageDownloader.loadComicImageUnwrapped(
          'cached',
          'source',
          'comic',
          'chapter',
        ),
        () => ImageDownloader.loadThumbnail('thumbnail', 'source'),
      ];
      final stale = openers.map((open) => open()).toList();
      final first = await prepare();
      final second = await prepare();
      first();
      first();
      for (final open in openers) {
        await expectLater(
          Future<void>.sync(() async => open().drain<void>()),
          throwsA(anything),
        );
      }
      expect(resolutions, 0);
      second();
      for (final stream in stale) {
        expect(await stream.toList(), isEmpty);
      }
      expect(resolutions, 0);
      await cache.writeCache('cached@source@comic@chapter', [9, 8, 7]);
      expect((await comic('cached').single).imageBytes, [9, 8, 7]);
      expect(resolutions, 0);
    },
  );

  test(
    'production cleanup failures survive ignored cancellation and are consumed once',
    () async {
      final retiredError = StateError('retired callback cleanup');
      final currentError = StateError('current callback cleanup');
      final retired = pending(retiredError);
      final current = pending(currentError);
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (_, key, _, _) =>
            (key == 'retired' ? retired : current).resolve(),
      );
      final subscription = comic('retired').listen((_) {});
      await retired.started.future;
      subscription.cancel().ignore();
      retired.finish();
      await pumpEventQueue();
      expect(retired.reference.releases, 1);
      comic('current').listen((_) {});
      await current.started.future;
      final preparing = ImageDownloader.prepareForExit();
      final checked = expectLater(
        preparing,
        throwsA(
          isA<SharedImageRequestFailure>()
              .having(
                (failure) => failure.failures,
                'both request failures',
                hasLength(2),
              )
              .having(
                (failure) => failure.failures.expand(
                  (entry) => (entry.error as ImageLoadingConfigCleanupFailure)
                      .failures
                      .map((cleanup) => cleanup.error),
                ),
                'all original cleanup causes',
                unorderedEquals([retiredError, currentError]),
              ),
        ),
      );
      current.finish();
      await checked;
      expect(current.reference.releases, 1);
      await cache.writeCache('retry@source@comic@chapter', [5]);
      expect((await comic('retry').single).imageBytes, [5]);
      (await prepare())();
    },
  );
}
