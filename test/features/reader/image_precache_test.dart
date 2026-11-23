import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/image_provider_lifecycle.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/network/image_stream.dart';
import '../../support/image_provider_fixture.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
);

class _Provider extends ReaderImageProvider {
  _Provider(String key, this.read, {this.decoder})
    : super(key, null, 'comic', 'chapter', 1);
  final Future<Uint8List> Function(void Function() checkStop) read;
  final ImageDecoderCallback? decoder;
  int loads = 0;
  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    loads++;
    return read(checkStop);
  }

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, decoder ?? decode);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 10);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nextProvider = 0;
  final owners = <ReaderImagePrecache>[];
  final sessions = <ImageWork>[];
  final releasePending = <void Function()>[];

  Future<void> frame() async {
    SchedulerBinding.instance.handleBeginFrame(Duration.zero);
    SchedulerBinding.instance.handleDrawFrame();
    await pumpEventQueue();
  }

  ImageWork work() {
    final result = ImageWork();
    sessions.add(result);
    return result;
  }

  ReaderImagePrecache owner(ImageWork session, {int maximumConcurrent = 1}) {
    final result = ReaderImagePrecache(
      work: session,
      maximumConcurrent: maximumConcurrent,
    );
    owners.add(result);
    return result;
  }

  _Provider provider(
    Future<Uint8List> Function(void Function()) read, {
    ImageDecoderCallback? decoder,
  }) => _Provider('prefetch-${nextProvider++}', read, decoder: decoder);

  Future<void> waitFor(bool Function() ready) async {
    final waiting = Stopwatch()..start();
    while (!ready() && waiting.elapsed < const Duration(seconds: 5)) {
      await frame();
    }
    expect(ready(), isTrue);
  }

  List<(_Provider, Completer<Uint8List>)> pendingImages(int count) =>
      List.generate(count, (_) {
        final bytes = Completer<Uint8List>();
        releasePending.add(() {
          if (!bytes.isCompleted) bytes.complete(_png);
        });
        return (provider((_) => bytes.future), bytes);
      });

  tearDown(() async {
    for (final release in releasePending) {
      release();
    }
    releasePending.clear();
    final closing = owners.map((cache) => cache.dispose()).toList();
    await frame();
    await Future.wait(closing);
    owners.clear();
    for (final session in sessions) {
      await session.dispose();
    }
    sessions.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await frame();
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  });

  test('a new window retains the current and incoming decode', () async {
    final precache = owner(work(), maximumConcurrent: 2);
    final images = pendingImages(3);
    final cache = PaintingBinding.instance.imageCache;
    precache.replace([images[0].$1, images[1].$1], ImageConfiguration.empty);
    expect(images.map((image) => image.$1.loads), [1, 1, 0]);
    precache.replace(
      [images[2].$1],
      ImageConfiguration.empty,
      retain: [images[0].$1, images[1].$1],
    );
    expect(cache.statusForKey(images[0].$1).pending, isTrue);
    expect(cache.statusForKey(images[1].$1).pending, isTrue);
    images[0].$2.complete(_png);
    images[1].$2.complete(_png);
    await waitFor(() => images[2].$1.loads == 1);
    expect(cache.statusForKey(images[0].$1).keepAlive, isTrue);
    expect(cache.statusForKey(images[1].$1).keepAlive, isTrue);
    expect(images.map((image) => image.$1.loads), [1, 1, 1]);
  });

  test(
    'cancelled native reads retain bounded admission and decode slots',
    () async {
      final session = work();
      final precache = owner(session, maximumConcurrent: 2);
      var admitted = 0;
      var peakAdmission = 0;
      final detach = session.retainTasks((_) {
        admitted++;
        if (admitted > peakAdmission) peakAdmission = admitted;
        return () => admitted--;
      });
      final images = pendingImages(6);
      try {
        precache.replace(
          images.map((image) => image.$1),
          ImageConfiguration.empty,
        );
        expect(images.map((image) => image.$1.loads), [1, 1, 0, 0, 0, 0]);
        expect(admitted, 4);
        precache.replace([
          images[4].$1,
          images[5].$1,
        ], ImageConfiguration.empty);
        await frame();
        expect(images[4].$1.loads, 0);
        expect(images[5].$1.loads, 0);
        images[0].$2.complete(_png);
        await waitFor(() => images[4].$1.loads == 1);
        expect(images[5].$1.loads, 0);
        images[1].$2.complete(_png);
        await waitFor(() => images[5].$1.loads == 1);
        expect(images[2].$1.loads, 0);
        expect(images[3].$1.loads, 0);
        expect(peakAdmission, lessThanOrEqualTo(4));
      } finally {
        detach();
      }
    },
  );

  test('the latest window prioritizes already admitted neighbours', () async {
    final precache = owner(work());
    final images = pendingImages(3);
    precache.replace(images.map((image) => image.$1), ImageConfiguration.empty);
    expect(images.map((image) => image.$1.loads), [1, 0, 0]);
    precache.replace([
      images[2].$1,
      images[1].$1,
      images[0].$1,
    ], ImageConfiguration.empty);
    images[0].$2.complete(_png);
    await waitFor(() => images[2].$1.loads == 1);
    expect(images[1].$1.loads, 0);
    images[2].$2.complete(_png);
    await waitFor(() => images[1].$1.loads == 1);
  });

  test(
    'a failed speculative image is not retried in the same window',
    () async {
      final precache = owner(work());
      final failed = provider(
        (_) async => throw Exception('Invalid Status Code: 404'),
      );
      final ready = provider((_) async => _png);
      final cache = PaintingBinding.instance.imageCache;
      precache.replace([failed, ready], ImageConfiguration.empty);
      await waitFor(() => cache.statusForKey(ready).keepAlive);
      for (var i = 0; i < 4; i++) {
        precache.replace([failed, ready], ImageConfiguration.empty);
        await frame();
      }
      expect(failed.loads, 1);
      precache.replace([ready, failed], ImageConfiguration.empty);
      await waitFor(() => failed.loads == 2);
    },
  );

  test('held sessions reject precache without resolving an image', () async {
    final session = work();
    final precache = owner(session);
    final bytes = Completer<Uint8List>();
    releasePending.add(() {
      if (!bytes.isCompleted) bytes.complete(_png);
    });
    final image = provider((_) => bytes.future);
    final release = session.holdForExit();
    precache.preload(image, ImageConfiguration.empty);
    expect(image.loads, 0);
    release();
    precache.preload(image, ImageConfiguration.empty);
    precache.preload(image, ImageConfiguration.empty);
    expect(image.loads, 1);
    final closing = precache.dispose();
    expect(precache.dispose(), same(closing));
    bytes.complete(_png);
    await frame();
    await closing;
    precache.preload(image, ImageConfiguration.empty);
    expect(image.loads, 1);
    final otherTask = session.start();
    expect(otherTask, isNotNull);
    otherTask!.finish();
  });

  test(
    'dispose waits for a pending local read and removes pending cache',
    () async {
      final session = work();
      final precache = owner(session);
      final bytes = Completer<Uint8List>();
      releasePending.add(() {
        if (!bytes.isCompleted) bytes.complete(_png);
      });
      final image = provider((_) => bytes.future);
      precache.preload(image, ImageConfiguration.empty);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(image).pending,
        isTrue,
      );
      var closed = false;
      final closing = precache.dispose().then((_) => closed = true);
      await frame();
      expect(closed, isFalse);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(image).pending,
        isFalse,
      );
      bytes.complete(_png);
      await closing;
      expect(closed, isTrue);
    },
  );

  test(
    'session preparation releases precache and waits before the view unmounts',
    () async {
      final session = work();
      final precache = owner(session);
      final bytes = Completer<Uint8List>();
      releasePending.add(() {
        if (!bytes.isCompleted) bytes.complete(_png);
      });
      final image = provider((_) => bytes.future);
      precache.preload(image, ImageConfiguration.empty);
      var ready = false;
      final preparing = session.prepareForExit().then((release) {
        ready = true;
        return release;
      });
      await frame();
      expect(ready, isFalse);
      bytes.complete(_png);
      final release = await preparing;
      expect(ready, isTrue);
      release();
      // The live view can start another owned preload after failed exit recovery.
      final next = provider((_) async => _png);
      precache.preload(next, ImageConfiguration.empty);
      expect(next.loads, 1);
      await pumpEventQueue();
      final closing = precache.dispose();
      await frame();
      await closing;
    },
  );

  test(
    'releasing one reader preserves another reader and visible consumer',
    () async {
      final bytes = Completer<Uint8List>();
      releasePending.add(() {
        if (!bytes.isCompleted) bytes.complete(_png);
      });
      final image = provider((_) => bytes.future);
      final first = owner(work());
      final second = owner(work());
      first.preload(image, ImageConfiguration.empty);
      second.preload(image, ImageConfiguration.empty);
      final stream = image.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!received.isCompleted) received.complete();
      });
      stream.addListener(listener);
      await first.dispose();
      await second.dispose();
      expect(image.loads, 1);
      expect(received.isCompleted, isFalse);
      bytes.complete(_png);
      await received.future;
      stream.removeListener(listener);
      await frame();
    },
  );

  test(
    'retired owner waits for its stream without evicting a same-key replacement',
    () async {
      final oldBytes = Completer<Uint8List>();
      final newBytes = Completer<Uint8List>();
      releasePending.add(() {
        if (!oldBytes.isCompleted) oldBytes.complete(_png);
        if (!newBytes.isCompleted) newBytes.complete(_png);
      });
      final oldImage = provider((_) => oldBytes.future);
      final newImage = _Provider(oldImage.imageKey, (_) => newBytes.future);
      expect(newImage, equals(oldImage));
      final first = owner(work());
      final second = owner(work());
      final cache = PaintingBinding.instance.imageCache;
      first.preload(oldImage, ImageConfiguration.empty);
      expect(oldImage.loads, 1);
      expect(cache.evict(oldImage, includeLive: true), isTrue);
      second.preload(newImage, ImageConfiguration.empty);
      expect(newImage.loads, 1);
      expect(cache.statusForKey(newImage).pending, isTrue);

      var oldClosed = false;
      final closing = first.dispose().then((_) => oldClosed = true);
      expect(cache.statusForKey(newImage).pending, isTrue);
      await frame();
      expect(oldClosed, isFalse);
      expect(cache.statusForKey(newImage).pending, isTrue);

      final stream = newImage.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!received.isCompleted) received.complete();
      });
      stream.addListener(listener);
      newBytes.complete(_png);
      await received.future;
      stream.removeListener(listener);
      expect(cache.statusForKey(newImage).keepAlive, isTrue);
      oldBytes.complete(_png);
      await closing;
      expect(oldClosed, isTrue);
      await frame();
      final newClosing = second.dispose();
      await frame();
      await newClosing;
      expect(cache.statusForKey(newImage).keepAlive, isTrue);
      expect(newImage.loads, 1);
    },
  );

  test(
    'successful decoded prefetch remains cached after frame release',
    () async {
      final precache = owner(work());
      final image = provider((_) async => _png);
      precache.preload(image, ImageConfiguration.empty);
      final stream = image.resolve(ImageConfiguration.empty);
      final received = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!received.isCompleted) received.complete();
      });
      stream.addListener(listener);
      await received.future;
      stream.removeListener(listener);
      await frame();
      final closing = precache.dispose();
      await frame();
      await closing;
      expect(
        PaintingBinding.instance.imageCache.statusForKey(image).keepAlive,
        isTrue,
      );
      expect(image.loads, 1);
    },
  );

  test(
    'release waits for accepted decoder completion and disposes its codec',
    () async {
      final decoded = Completer<ui.Codec>();
      var decoding = false;
      final nativeImage = await opaqueTestImage();
      final codec = TrackedImageCodec(Future.value(_Frame(nativeImage)));
      releasePending.add(() {
        if (!decoded.isCompleted) decoded.complete(codec);
        if (!nativeImage.debugDisposed) nativeImage.dispose();
      });
      final image = provider(
        (_) async => _png,
        decoder: (buffer, {getTargetSize}) {
          buffer.dispose();
          decoding = true;
          return decoded.future;
        },
      );
      final precache = owner(work());
      precache.preload(image, ImageConfiguration.empty);
      await pumpEventQueue();
      expect(decoding, isTrue);
      var closed = false;
      final closing = precache.dispose().then((_) => closed = true);
      await frame();
      expect(closed, isFalse);
      decoded.complete(codec);
      await closing;
      expect(codec.disposals, 1);
      expect(codec.reads, 0);
      nativeImage.dispose();
    },
  );

  test(
    'active cleanup error and final provider cleanup report the same cause once',
    () async {
      final cleanupError = StateError('subscription cleanup');
      final cleanupStack = StackTrace.fromString('subscription cleanup stack');
      final error = ImageStreamCleanupFailure([
        (
          stage: 'subscription cancellation',
          error: cleanupError,
          stack: cleanupStack,
        ),
      ]);
      final stack = StackTrace.fromString('original image stream stack');
      final image = provider((_) => Future<Uint8List>.error(error, stack));
      final session = work();
      final precache = owner(session);
      precache.preload(image, ImageConfiguration.empty);
      await pumpEventQueue();
      final observed = expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures,
            'one original error with its original stack',
            [(error: error, stack: stack)],
          ),
        ),
      );
      await frame();
      await observed;
      await precache.dispose();
      (await BaseImageProvider.prepareForExit())();
      (await session.prepareForExit())();
    },
  );

  test(
    'nested provider failures keep distinct causes and original stacks once',
    () async {
      final first = StateError('native frame');
      final firstStack = StackTrace.fromString('native frame stack');
      final second = StateError('native codec release');
      final secondStack = StackTrace.fromString('native codec release stack');
      final wrapped = ImageProviderPreparationFailure([
        (error: first, stack: firstStack),
        (
          error: ImageProviderPreparationFailure([
            (error: first, stack: firstStack),
            (error: second, stack: secondStack),
          ]),
          stack: StackTrace.fromString('intermediate aggregation stack'),
        ),
      ]);
      final image = provider((_) => Future<Uint8List>.error(wrapped));
      final session = work();
      final precache = owner(session);
      precache.preload(image, ImageConfiguration.empty);
      await pumpEventQueue();
      final observed = expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures,
            'distinct original causes and stacks',
            [
              (error: first, stack: firstStack),
              (error: second, stack: secondStack),
            ],
          ),
        ),
      );
      await frame();
      await observed;
      await precache.dispose();
      (await BaseImageProvider.prepareForExit())();
    },
  );

  test(
    'late native frame failure belongs to the last reader and is not replayed globally',
    () async {
      final nativeFrame = Completer<ui.FrameInfo>();
      final codec = TrackedImageCodec(nativeFrame.future);
      final error = StateError('late native frame failure');
      final stack = StackTrace.fromString('original native frame stack');
      final image = provider(
        (_) async => _png,
        decoder: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      final session = work();
      final precache = owner(session);
      precache.preload(image, ImageConfiguration.empty);
      await pumpEventQueue();
      expect(codec.reads, 1);
      final observed = expectLater(
        session.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (failure) => failure.failures,
            'original native error and stack returned to reader',
            [(error: error, stack: stack)],
          ),
        ),
      );
      await frame();
      nativeFrame.completeError(error, stack);
      await observed;
      expect(codec.disposals, 1);
      await precache.dispose();
      // A later unrelated window shutdown must not report this consumed failure.
      (await BaseImageProvider.prepareForExit())();
      (await session.prepareForExit())();
    },
  );

  test(
    'release waits for native frame creation and disposes a late frame',
    () async {
      final nativeFrame = Completer<ui.FrameInfo>();
      final codec = TrackedImageCodec(nativeFrame.future);
      final nativeImage = await opaqueTestImage();
      releasePending.add(() {
        if (!nativeFrame.isCompleted) nativeFrame.complete(_Frame(nativeImage));
      });
      final image = provider(
        (_) async => _png,
        decoder: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      final precache = owner(work());
      precache.preload(image, ImageConfiguration.empty);
      await pumpEventQueue();
      expect(codec.reads, 1);
      var closed = false;
      final closing = precache.dispose().then((_) => closed = true);
      await frame();
      expect(closed, isFalse);
      nativeFrame.complete(_Frame(nativeImage));
      await closing;
      expect(codec.disposals, 1);
      expect(nativeImage.debugDisposed, isTrue);
    },
  );
}
