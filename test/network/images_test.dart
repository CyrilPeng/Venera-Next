import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/images.dart';

class _FakeJSInvokable extends JSInvokable {
  _FakeJSInvokable(this.callback);

  final dynamic Function(List args) callback;

  int destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) {
    return callback(args);
  }

  @override
  void destroy() {
    destroyCount++;
  }
}

void main() {
  tearDown(() {
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    ImageDownloader.cancelAllLoadingImages();
  });

  test('loadComicImage stops retrying when retry budget is exhausted', () {
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 1,
        hasOnLoadFailed: true,
      ),
      isTrue,
    );
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 0,
        hasOnLoadFailed: true,
      ),
      isFalse,
    );
    expect(
      ImageDownloader.debugShouldRetryImageLoad(
        retriesRemaining: 5,
        hasOnLoadFailed: false,
      ),
      isFalse,
    );
  });

  test('image onResponse callback is freed after valid result', () async {
    final callback = _FakeJSInvokable((args) {
      expect(args.single, isA<Uint8List>());
      return <int>[3, 2, 1];
    });

    final result = await ImageDownloader.debugApplyImageResponseCallback(
      callback,
      <int>[1, 2, 3],
    );

    expect(result, <int>[3, 2, 1]);
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after future result', () async {
    final callback = _FakeJSInvokable((args) async => <int>[4, 5, 6]);

    final result = await ImageDownloader.debugApplyImageResponseCallback(
      callback,
      <int>[1, 2, 3],
    );

    expect(result, <int>[4, 5, 6]);
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after invalid result', () async {
    final callback = _FakeJSInvokable((args) => 'bad-result');

    await expectLater(
      ImageDownloader.debugApplyImageResponseCallback(callback, <int>[1]),
      throwsA('Error: Invalid onResponse result.'),
    );
    expect(callback.destroyCount, 1);
  });

  test('image onResponse callback is freed after callback error', () async {
    final error = StateError('boom');
    final callback = _FakeJSInvokable((args) => throw error);

    await expectLater(
      ImageDownloader.debugApplyImageResponseCallback(callback, <int>[1]),
      throwsA(same(error)),
    );
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after valid config', () async {
    final callback = _FakeJSInvokable((args) => <String, dynamic>{
          'url': 'next-url',
        });

    final result = await ImageDownloader.debugResolveImageLoadFailure(
      callback,
    );

    expect(result, {'url': 'next-url'});
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after future config', () async {
    final callback = _FakeJSInvokable(
      (args) async => <String, dynamic>{'url': 'async-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(
      callback,
    );

    expect(result, {'url': 'async-url'});
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback accepts dynamically typed config', () async {
    final callback = _FakeJSInvokable(
      (args) => <dynamic, dynamic>{'url': 'dynamic-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(
      callback,
    );

    expect(result, {'url': 'dynamic-url'});
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after invalid config', () async {
    final callback = _FakeJSInvokable((args) => 'bad-config');

    final result = await ImageDownloader.debugResolveImageLoadFailure(
      callback,
    );

    expect(result, isNull);
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback rejects non-string config keys', () async {
    final callback = _FakeJSInvokable(
      (args) => <dynamic, dynamic>{1: 'bad-key'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(
      callback,
    );

    expect(result, isNull);
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after callback error', () async {
    final error = StateError('boom');
    final callback = _FakeJSInvokable((args) => throw error);

    await expectLater(
      ImageDownloader.debugResolveImageLoadFailure(callback),
      throwsA(same(error)),
    );
    expect(callback.destroyCount, 1);
  });

  test(
    'loadComicImage cancels source stream after last listener cancels',
    () async {
      final sourceCanceled = Completer<void>();
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () {
          if (!sourceCanceled.isCompleted) {
            sourceCanceled.complete();
          }
        },
      );
      addTearDown(() async {
        if (!source.isClosed) {
          await source.close();
        }
      });

      ImageDownloader.debugLoadComicImageUnwrapped =
          (imageKey, sourceKey, cid, eid) => source.stream;

      final subscription = ImageDownloader.loadComicImage(
        'image-1',
        'source',
        'comic',
        'chapter',
      ).listen((_) {});
      await pumpEventQueue();

      await subscription.cancel();

      await sourceCanceled.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'loadComicImage recreates stream immediately after listener cancels',
    () async {
      final firstCancelGate = Completer<void>();
      final firstCanceled = Completer<void>();
      final firstSource = StreamController<ImageDownloadProgress>(
        onCancel: () {
          if (!firstCanceled.isCompleted) {
            firstCanceled.complete();
          }
          return firstCancelGate.future;
        },
      );
      final secondSource = StreamController<ImageDownloadProgress>();
      addTearDown(() async {
        if (!firstCancelGate.isCompleted) {
          firstCancelGate.complete();
        }
        if (!firstSource.isClosed) {
          await firstSource.close();
        }
        if (!secondSource.isClosed) {
          await secondSource.close();
        }
      });

      var loadCount = 0;
      ImageDownloader.debugLoadComicImageUnwrapped =
          (imageKey, sourceKey, cid, eid) {
            loadCount++;
            return loadCount == 1 ? firstSource.stream : secondSource.stream;
          };

      final firstSubscription = ImageDownloader.loadComicImage(
        'image-reload',
        'source',
        'comic',
        'chapter',
      ).listen((_) {});
      await pumpEventQueue();

      final firstCancel = firstSubscription.cancel();
      await firstCanceled.future.timeout(const Duration(seconds: 1));

      final events = <ImageDownloadProgress>[];
      final secondSubscription = ImageDownloader.loadComicImage(
        'image-reload',
        'source',
        'comic',
        'chapter',
      ).listen(events.add);
      await pumpEventQueue();

      expect(loadCount, 2);

      secondSource.add(
        ImageDownloadProgress(
          currentBytes: 1,
          totalBytes: 1,
          imageBytes: Uint8List(1),
        ),
      );
      await pumpEventQueue();

      expect(events, hasLength(1));

      await secondSubscription.cancel();
      firstCancelGate.complete();
      await firstCancel.timeout(const Duration(seconds: 1));
    },
  );

  test('cancelAllLoadingImages cancels active source streams', () async {
    final sourceCanceled = Completer<void>();
    final source = StreamController<ImageDownloadProgress>(
      onCancel: () {
        if (!sourceCanceled.isCompleted) {
          sourceCanceled.complete();
        }
      },
    );
    addTearDown(() async {
      if (!source.isClosed) {
        await source.close();
      }
    });

    ImageDownloader.debugLoadComicImageUnwrapped =
        (imageKey, sourceKey, cid, eid) => source.stream;

    final subscription = ImageDownloader.loadComicImage(
      'image-2',
      'source',
      'comic',
      'chapter',
    ).listen((_) {});
    await pumpEventQueue();

    ImageDownloader.cancelAllLoadingImages();

    await sourceCanceled.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
  });
}
