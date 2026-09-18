import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/log.dart';

class _TestImage extends BaseImageProvider<_TestImage> {
  _TestImage({this.emptyCount = 1});
  final int emptyCount;
  int attempts = 0;
  @override
  String get key => 'test-${identityHashCode(hash)}';
  final Object hash = Object();
  @override
  Future<_TestImage> obtainKey(ImageConfiguration configuration) async => this;
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    attempts++;
    if (attempts <= emptyCount) return Uint8List(0);
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Object?> resolveImage(_TestImage provider) async {
    final result = Completer<Object?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (image, synchronous) {
        image.dispose();
        if (!result.isCompleted) result.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.complete(error);
      },
    );
    stream.addListener(listener);
    try {
      return await result.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
      await provider.evict();
    }
  }

  test('empty bytes retry automatically and eventually decode', () async {
    final provider = _TestImage();
    expect(await resolveImage(provider), isNull);
    expect(provider.attempts, 2);
  });

  test('permanently empty bytes stop after three attempts', () async {
    final provider = _TestImage(emptyCount: 99);
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    final error = await resolveImage(provider);
    expect(error.toString(), contains('Empty image data'));
    expect(provider.attempts, 3);
  });

  test('retry delay completes when cancel signal fires', () async {
    final cancel = Completer<void>();
    var completed = false;

    final wait =
        BaseImageProvider.debugWaitForRetryDelay(
          const Duration(seconds: 30),
          cancel.future,
        ).then((_) {
          completed = true;
        });

    await pumpEventQueue();
    expect(completed, isFalse);

    cancel.complete();
    await wait.timeout(const Duration(seconds: 1));

    expect(completed, isTrue);
  });

  test('retry delay still completes normally without cancel', () async {
    await BaseImageProvider.debugWaitForRetryDelay(
      Duration.zero,
      Completer<void>().future,
    ).timeout(const Duration(seconds: 1));
  });
}
