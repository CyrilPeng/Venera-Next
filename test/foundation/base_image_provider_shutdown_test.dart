import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/image_loading_config.dart';
import 'package:venera_next/network/image_http_client.dart';

class _Provider extends BaseImageProvider<_Provider> {
  _Provider(this.read);
  final Future<Uint8List> Function(int attempt) read;
  int loads = 0;
  @override
  String get key => 'shutdown-${identityHashCode(this)}';
  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) async => this;
  @override
  Future<Uint8List> load(chunkEvents, checkStop) => read(++loads);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 10);
}

class _Codec implements ui.Codec {
  _Codec(this.frame, {this.frameCount = 1, this.disposeFailure});
  final Future<ui.FrameInfo> Function(int attempt) frame;
  int reads = 0;
  int disposals = 0;
  final Object? disposeFailure;
  @override
  final int frameCount;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() => frame(++reads);
  @override
  void dispose() {
    disposals++;
    if (disposeFailure != null) throw disposeFailure!;
  }
}

Future<ui.Image> _image() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff00ff00), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(1, 1);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await pumpEventQueue();
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  });

  test(
    'holds synchronously stop admission and release independently',
    () async {
      final first = BaseImageProvider.prepareForExit();
      final second = BaseImageProvider.prepareForExit();
      final provider = _Provider((_) async => Uint8List(1));
      final frame = await _image();
      final codec = _Codec((_) async => _Frame(frame));
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return codec;
      });
      final received = Completer<void>();
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        received.complete();
      });
      completer.addListener(listener);
      final releaseFirst = await first;
      final releaseSecond = await second;
      addTearDown(() {
        releaseFirst();
        releaseSecond();
        completer.removeListener(listener);
      });
      await pumpEventQueue();
      expect(provider.loads, 0);
      releaseFirst();
      releaseFirst();
      await pumpEventQueue();
      expect(provider.loads, 0);
      releaseSecond();
      await received.future;
      expect(provider.loads, 1);
    },
  );

  test('shutdown waits for a local read and resumes its live stream', () async {
    final read = Completer<Uint8List>();
    final provider = _Provider(
      (attempt) => attempt == 1 ? read.future : Future.value(Uint8List(1)),
    );
    final frame = await _image();
    var decodes = 0;
    final codec = _Codec((_) async => _Frame(frame));
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      decodes++;
      buffer.dispose();
      return codec;
    });
    final received = Completer<void>();
    final listener = ImageStreamListener((image, _) {
      image.dispose();
      received.complete();
    });
    completer.addListener(listener);
    addTearDown(() => completer.removeListener(listener));
    await pumpEventQueue();
    var prepared = false;
    final preparing = BaseImageProvider.prepareForExit().then((release) {
      prepared = true;
      return release;
    });
    await pumpEventQueue();
    expect(prepared, isFalse);
    read.complete(Uint8List(1));
    final release = await preparing;
    addTearDown(release);
    expect(decodes, 0);
    expect(received.isCompleted, isFalse);
    release();
    await received.future;
    expect(provider.loads, 2);
    expect(decodes, 1);
  });

  test('final listener removal while held prevents restart', () async {
    final read = Completer<Uint8List>();
    final provider = _Provider((_) => read.future);
    var decodes = 0;
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      decodes++;
      buffer.dispose();
      throw StateError('must not decode');
    });
    final first = ImageStreamListener((image, _) => image.dispose());
    final second = ImageStreamListener((image, _) => image.dispose());
    completer.addListener(first);
    completer.addListener(second);
    await pumpEventQueue();
    completer.removeListener(first);
    expect(BaseImageProvider.debugActiveLoadCount, 1);
    final preparation = BaseImageProvider.prepareForExit();
    completer.removeListener(second);
    read.complete(Uint8List(1));
    final release = await preparation;
    release();
    await pumpEventQueue();
    expect(provider.loads, 1);
    expect(decodes, 0);
  });

  test('a late codec is disposed once after real decoder completion', () async {
    final decoding = Completer<ui.Codec>();
    final provider = _Provider((_) async => Uint8List(1));
    final codec = _Codec((_) => throw StateError('must not decode frame'));
    var decoded = false;
    final completer = provider.loadImage(provider, (buffer, {getTargetSize}) {
      // The decoder owns and disposes the buffer even while its result is held.
      buffer.dispose();
      decoded = true;
      return decoding.future;
    });
    final listener = ImageStreamListener((image, _) => image.dispose());
    completer.addListener(listener);
    await pumpEventQueue();
    expect(decoded, isTrue);
    var prepared = false;
    final preparation = BaseImageProvider.prepareForExit().then((release) {
      prepared = true;
      return release;
    });
    await pumpEventQueue();
    expect(prepared, isFalse);
    completer.removeListener(listener);
    decoding.complete(codec);
    final release = await preparation;
    release();
    expect(codec.disposals, 1);
    expect(codec.reads, 0);
  });

  test(
    'native frame decode drains and preserves the same frame for recovery',
    () async {
      final nativeFrame = Completer<ui.FrameInfo>();
      final lateImage = await _image();
      final codec = _Codec((_) => nativeFrame.future);
      final provider = _Provider((_) async => Uint8List(1));
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return codec;
      });
      final received = Completer<void>();
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        received.complete();
      });
      completer.addListener(listener);
      addTearDown(() => completer.removeListener(listener));
      await pumpEventQueue();
      expect(codec.reads, 1);
      var prepared = false;
      final preparation = BaseImageProvider.prepareForExit().then((release) {
        prepared = true;
        return release;
      });
      await pumpEventQueue();
      expect(prepared, isFalse);
      nativeFrame.complete(_Frame(lateImage));
      final release = await preparation;
      addTearDown(release);
      expect(lateImage.debugDisposed, isFalse);
      expect(codec.disposals, 0);
      expect(received.isCompleted, isFalse);
      release();
      await received.future;
      expect(codec.reads, 1);
      expect(lateImage.debugDisposed, isTrue);
      expect(provider.loads, 1);
    },
  );

  test('disposing during native frame decode defers codec release', () async {
    final nativeFrame = Completer<ui.FrameInfo>();
    final lateImage = await _image();
    final codec = _Codec((_) => nativeFrame.future);
    final provider = _Provider((_) async => Uint8List(1));
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      buffer.dispose();
      return codec;
    });
    final listener = ImageStreamListener((image, _) => image.dispose());
    completer.addListener(listener);
    await pumpEventQueue();
    completer.removeListener(listener);
    expect(codec.disposals, 0);
    final preparation = BaseImageProvider.prepareForExit();
    nativeFrame.complete(_Frame(lateImage));
    final release = await preparation;
    release();
    expect(lateImage.debugDisposed, isTrue);
    expect(codec.disposals, 1);
    expect(codec.reads, 1);
  });

  test('failed preparation releases only its own hold', () async {
    final lifecycle = ImageProviderLifecycle();
    final attempt = lifecycle.tryBegin()!;
    final failure = StateError('cleanup failed');
    final first = lifecycle.prepareForExit();
    final observed = expectLater(
      first,
      throwsA(isA<ImageProviderPreparationFailure>()),
    );
    attempt.finish(error: failure, stack: StackTrace.current);
    final second = await lifecycle.prepareForExit();
    await observed;
    expect(lifecycle.isHeld, isTrue);
    expect(lifecycle.tryBegin(), isNull);
    second();
    final next = lifecycle.tryBegin();
    expect(next, isNotNull);
    next!.finish();
  });

  test(
    'retired cleanup failure is consumed once by next preparation',
    () async {
      final lifecycle = ImageProviderLifecycle();
      final attempt = lifecycle.tryBegin()!;
      attempt.cancel();
      attempt.finish(
        error: StateError('late cleanup'),
        stack: StackTrace.current,
      );
      expect(lifecycle.activeCount, 0);
      await expectLater(
        lifecycle.prepareForExit(),
        throwsA(isA<ImageProviderPreparationFailure>()),
      );
      expect(lifecycle.isHeld, isFalse);
      final release = await lifecycle.prepareForExit();
      release();
    },
  );

  test(
    'observed active failure is not repeated in a later preparation',
    () async {
      final lifecycle = ImageProviderLifecycle();
      final attempt = lifecycle.tryBegin()!;
      final first = expectLater(
        lifecycle.prepareForExit(),
        throwsA(isA<ImageProviderPreparationFailure>()),
      );
      final second = expectLater(
        lifecycle.prepareForExit(),
        throwsA(isA<ImageProviderPreparationFailure>()),
      );
      attempt.finish(
        error: StateError('active cleanup'),
        stack: StackTrace.current,
      );
      await Future.wait([first, second]);
      final release = await lifecycle.prepareForExit();
      release();
    },
  );

  test(
    'retired codec cleanup failure reaches the next global preparation',
    () async {
      final muted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = muted);
      final nativeFrame = Completer<ui.FrameInfo>();
      final image = await _image();
      final codec = _Codec(
        (_) => nativeFrame.future,
        disposeFailure: StateError('native disposal'),
      );
      final provider = _Provider((_) async => Uint8List(1));
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return codec;
      });
      final listener = ImageStreamListener((image, _) => image.dispose());
      completer.addListener(listener);
      await pumpEventQueue();
      completer.removeListener(listener);
      nativeFrame.complete(_Frame(image));
      await pumpEventQueue();
      expect(codec.disposals, 1);
      expect(image.debugDisposed, isTrue);
      expect(BaseImageProvider.debugActiveLoadCount, 0);
      await expectLater(
        BaseImageProvider.prepareForExit(),
        throwsA(isA<ImageProviderPreparationFailure>()),
      );
      final release = await BaseImageProvider.prepareForExit();
      release();
    },
  );

  test('a keep-alive owner survives temporary listener removal', () async {
    final read = Completer<Uint8List>();
    final image = await _image();
    final codec = _Codec((_) async => _Frame(image));
    final provider = _Provider((_) => read.future);
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      buffer.dispose();
      return codec;
    });
    final handle = completer.keepAlive();
    final received = Completer<void>();
    final listener = ImageStreamListener((image, _) {
      image.dispose();
      received.complete();
    });
    var otherReceived = 0;
    final otherListener = ImageStreamListener((image, _) {
      image.dispose();
      otherReceived++;
    });
    completer.addListener(listener);
    completer.addListener(otherListener);
    await pumpEventQueue();
    completer.removeListener(listener);
    completer.removeListener(otherListener);
    expect(BaseImageProvider.debugActiveLoadCount, 1);
    completer.addListener(listener);
    completer.addListener(otherListener);
    read.complete(Uint8List(1));
    await received.future;
    expect(provider.loads, 1);
    expect(otherReceived, 1);
    completer.removeListener(listener);
    completer.removeListener(otherListener);
    handle.dispose();
    expect(codec.disposals, 1);
  });

  final cleanup = ImageLoadingConfigCleanupFailure([
    (error: StateError('reference cleanup'), stack: StackTrace.current),
  ]);
  for (final failure in <Object>[
    cleanup,
    ImageLoadingConfigFailure(
      cause: StateError('config failed'),
      stackTrace: StackTrace.current,
      cleanupFailure: cleanup,
    ),
    ImageHttpCleanupFailure(
      cause: null,
      stackTrace: null,
      failures: [
        (
          stage: 'native close',
          error: StateError('native cleanup'),
          stack: StackTrace.current,
        ),
      ],
    ),
  ]) {
    test('cleanup ${failure.runtimeType} is never retried', () async {
      final muted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = muted);
      final provider = _Provider((_) => Future.error(failure));
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        throw StateError('must not decode');
      });
      Object? received;
      final listener = ImageStreamListener(
        (image, _) => image.dispose(),
        onError: (Object error, StackTrace? stack) {
          received = error;
        },
      );
      completer.addListener(listener);
      addTearDown(() => completer.removeListener(listener));
      await pumpEventQueue();
      expect(received, same(failure));
      expect(provider.loads, 1);
      await expectLater(
        BaseImageProvider.prepareForExit(),
        throwsA(isA<ImageProviderPreparationFailure>()),
      );
    });
  }

  for (final removeWhileHeld in [false, true]) {
    testWidgets('scheduled animation frame is held; remove=$removeWhileHeld', (
      tester,
    ) async {
      late _Provider provider;
      late _Codec codec;
      late ImageStreamCompleter completer;
      late ImageStreamListener listener;
      late ui.Image firstImage;
      late ui.Image secondImage;
      var received = 0;
      await tester.runAsync(() async {
        firstImage = await _image();
        secondImage = await _image();
        codec = _Codec(
          (attempt) async => _Frame(attempt == 1 ? firstImage : secondImage),
          frameCount: 2,
        );
        provider = _Provider((_) async => Uint8List(1));
        completer = provider.loadImage(provider, (
          buffer, {
          getTargetSize,
        }) async {
          buffer.dispose();
          return codec;
        });
        listener = ImageStreamListener((image, _) {
          received++;
          image.dispose();
        });
        completer.addListener(listener);
        await pumpEventQueue();
      });
      expect(codec.reads, 1);
      expect(received, 0);
      final release = await BaseImageProvider.prepareForExit();
      await tester.pump();
      expect(received, 0);
      expect(firstImage.debugDisposed, isTrue);
      expect(firstImage.debugGetOpenHandleStackTraces(), hasLength(1));
      if (removeWhileHeld) {
        completer.removeListener(listener);
        expect(firstImage.debugGetOpenHandleStackTraces(), isEmpty);
        release();
        await tester.pump();
        expect(codec.reads, 1);
        secondImage.dispose();
      } else {
        release();
        expect(received, 1);
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump(const Duration(milliseconds: 20));
        expect(received, 2);
        expect(codec.disposals, 1);
        completer.removeListener(listener);
        expect(firstImage.debugGetOpenHandleStackTraces(), isEmpty);
        expect(secondImage.debugGetOpenHandleStackTraces(), isEmpty);
      }
      expect(codec.disposals, 1);
    });
  }
}
