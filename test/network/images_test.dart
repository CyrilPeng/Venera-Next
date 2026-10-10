import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/shared_image_requests.dart';

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
  tearDown(() async {
    ImageDownloader.configureSourceImageLoading();
    await ImageDownloader.cancelAllLoadingImages();
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
    final callback = _FakeJSInvokable(
      (args) => <String, dynamic>{'url': 'next-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, {'url': 'next-url'});
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback is freed after future config', () async {
    final callback = _FakeJSInvokable(
      (args) async => <String, dynamic>{'url': 'async-url'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, {'url': 'async-url'});
    expect(callback.destroyCount, 1);
  });

  test(
    'image onLoadFailed callback accepts dynamically typed config',
    () async {
      final callback = _FakeJSInvokable(
        (args) => <dynamic, dynamic>{'url': 'dynamic-url'},
      );

      final result = await ImageDownloader.debugResolveImageLoadFailure(
        callback,
      );

      expect(result, {'url': 'dynamic-url'});
      expect(callback.destroyCount, 1);
    },
  );

  test('image onLoadFailed callback is freed after invalid config', () async {
    final callback = _FakeJSInvokable((args) => 'bad-config');

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

    expect(result, isNull);
    expect(callback.destroyCount, 1);
  });

  test('image onLoadFailed callback rejects non-string config keys', () async {
    final callback = _FakeJSInvokable(
      (args) => <dynamic, dynamic>{1: 'bad-key'},
    );

    final result = await ImageDownloader.debugResolveImageLoadFailure(callback);

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
    'shared image owner cancels source after last listener cancels',
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

      final requests = SharedImageRequests<ImageDownloadProgress>();
      addTearDown(requests.cancelAll);

      final subscription = requests
          .open((_) => source.stream, key: 'image-1')
          .listen((_) {});
      await pumpEventQueue();

      await subscription.cancel();

      await sourceCanceled.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'shared image owner recreates stream before old cancellation drains',
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
      final requests = SharedImageRequests<ImageDownloadProgress>();
      addTearDown(requests.cancelAll);
      Stream<ImageDownloadProgress> load() {
        loadCount++;
        return loadCount == 1 ? firstSource.stream : secondSource.stream;
      }

      final firstSubscription = requests
          .open((_) => load(), key: 'image-reload')
          .listen((_) {});
      await pumpEventQueue();

      final firstCancel = firstSubscription.cancel();
      await firstCanceled.future.timeout(const Duration(seconds: 1));

      final events = <ImageDownloadProgress>[];
      final secondSubscription = requests
          .open((_) => load(), key: 'image-reload')
          .listen(events.add);
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

  test('shared image owner cancels all active source streams', () async {
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

    final requests = SharedImageRequests<ImageDownloadProgress>();
    addTearDown(requests.cancelAll);

    final subscription = requests
        .open((_) => source.stream, key: 'image-2')
        .listen((_) {});
    await pumpEventQueue();

    await requests.cancelAll();

    await sourceCanceled.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
  });
}
