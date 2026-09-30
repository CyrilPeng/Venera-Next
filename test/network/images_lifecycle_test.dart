import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/cache_manager.dart';
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
    ImageDownloader.debugResetSourceImageLoading();
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
    await second.cancel();
    expect(scope.cancelToken.isCancelled, true);
    configuration.complete({'url': 'https://example.invalid/late'});
    await pumpEventQueue();
    expect(await cache.findCache('image@source@comic@chapter'), isNull);
  });
}
