import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/network/images.dart';

const provider = ReaderImageProvider(
  'prefetch-image',
  null,
  'comic',
  'chapter',
  1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> finishFrame() async {
    SchedulerBinding.instance.handleBeginFrame(Duration.zero);
    SchedulerBinding.instance.handleDrawFrame();
    await pumpEventQueue();
  }

  late StreamController<ImageDownloadProgress> source;
  var loads = 0;
  var cancelled = 0;
  setUp(() {
    loads = 0;
    cancelled = 0;
    source = StreamController<ImageDownloadProgress>(
      onCancel: () => cancelled++,
    );
    ImageDownloader.debugLoadComicImageUnwrapped = (a, b, c, d) {
      loads++;
      return source.stream;
    };
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    await source.close();
  });

  test(
    'deduplicates and releases pending cache and download listeners',
    () async {
      final owner = ReaderImagePrecache();
      owner.preload(provider, ImageConfiguration.empty);
      owner.preload(provider, ImageConfiguration.empty);
      expect(loads, 1);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).pending,
        true,
      );
      owner.dispose();
      owner.dispose();
      await finishFrame();
      expect(cancelled, 1);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).pending,
        false,
      );
      owner.preload(provider, ImageConfiguration.empty);
      expect(loads, 1);
    },
  );

  test(
    'releasing prefetch owners preserves another visible listener',
    () async {
      final first = ReaderImagePrecache();
      final second = ReaderImagePrecache();
      first.preload(provider, ImageConfiguration.empty);
      second.preload(provider, ImageConfiguration.empty);
      final stream = provider.resolve(ImageConfiguration.empty);
      var chunks = 0;
      final listener = ImageStreamListener(
        (image, _) => image.dispose(),
        onChunk: (_) => chunks++,
      );
      stream.addListener(listener);
      first.dispose();
      second.dispose();
      await pumpEventQueue();
      expect(cancelled, 0);
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      await pumpEventQueue();
      expect(chunks, 1);
      expect(loads, 1);
      stream.removeListener(listener);
      await finishFrame();
      expect(cancelled, 1);
    },
  );

  test('failed prefetch releases its pending cache listener', () async {
    final previousMuted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = previousMuted);
    final owner = ReaderImagePrecache();
    owner.preload(provider, ImageConfiguration.empty);
    source.addError('Invalid Status Code: 403');
    await pumpEventQueue();
    await finishFrame();
    expect(
      PaintingBinding.instance.imageCache.statusForKey(provider).pending,
      false,
    );
    expect(cancelled, 1);
    owner.dispose();
  });

  test(
    'decoded prefetch keeps cached image and frame cleanup is idempotent',
    () async {
      final owner = ReaderImagePrecache();
      owner.preload(provider, ImageConfiguration.empty);
      final stream = provider.resolve(ImageConfiguration.empty);
      final decoded = Completer<void>();
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        if (!decoded.isCompleted) decoded.complete();
      });
      stream.addListener(listener);
      {
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
        );
        source.add(
          ImageDownloadProgress(
            currentBytes: bytes.length,
            totalBytes: bytes.length,
            imageBytes: bytes,
          ),
        );
        await decoded.future.timeout(const Duration(seconds: 5));
      }
      stream.removeListener(listener);
      owner.dispose();
      await finishFrame();
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        true,
      );
      expect(loads, 1);
    },
  );
}
