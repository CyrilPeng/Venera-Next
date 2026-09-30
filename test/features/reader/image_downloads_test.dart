import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_downloads.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/images.dart';

void main() {
  setUp(() => Log.isMuted = true);
  tearDown(() {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    Log.isMuted = false;
  });

  test(
    'prefetch deduplicates and releases only its shared subscription',
    () async {
      var loads = 0;
      var cancelled = 0;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled++,
      );
      ImageDownloader.debugLoadComicImageUnwrapped = (a, b, c, d) {
        loads++;
        return source.stream;
      };
      final first = ReaderImageDownloads();
      final second = ReaderImageDownloads();
      first.preload('image', 'source', 'comic', 'chapter');
      first.preload('image', 'source', 'comic', 'chapter');
      second.preload('image', 'source', 'comic', 'chapter');
      final events = <ImageDownloadProgress>[];
      final visible = ImageDownloader.loadComicImage(
        'image',
        'source',
        'comic',
        'chapter',
      ).listen(events.add);
      expect(loads, 1);
      await first.dispose();
      await second.dispose();
      expect(cancelled, 0);
      source.add(const ImageDownloadProgress(currentBytes: 1, totalBytes: 2));
      await pumpEventQueue();
      expect(events, hasLength(1));
      await visible.cancel();
      await pumpEventQueue();
      expect(cancelled, 1);
      await source.close();
    },
  );

  test(
    'dispose releases stalled prefetch and prevents new downloads',
    () async {
      var cancelled = false;
      var loads = 0;
      final source = StreamController<ImageDownloadProgress>(
        onCancel: () => cancelled = true,
      );
      ImageDownloader.debugLoadComicImageUnwrapped = (a, b, c, d) {
        loads++;
        return source.stream;
      };
      final owner = ReaderImageDownloads();
      owner.preload('image', null, 'comic', 'chapter');
      final disposal = owner.dispose();
      expect(owner.dispose(), same(disposal));
      await disposal;
      expect(cancelled, true);
      owner.preload('another', null, 'comic', 'chapter');
      expect(loads, 1);
      await source.close();
    },
  );

  test(
    'completed and failed prefetches release handles and allow retry',
    () async {
      var loads = 0;
      final sources = <StreamController<ImageDownloadProgress>>[];
      ImageDownloader.debugLoadComicImageUnwrapped = (a, b, c, d) {
        loads++;
        final source = StreamController<ImageDownloadProgress>();
        sources.add(source);
        return source.stream;
      };
      final owner = ReaderImageDownloads();
      owner.preload('image', null, 'comic', 'chapter');
      sources.last.addError(StateError('offline'));
      await pumpEventQueue();
      owner.preload('image', null, 'comic', 'chapter');
      expect(loads, 2);
      sources.last.add(
        ImageDownloadProgress(
          currentBytes: 1,
          totalBytes: 1,
          imageBytes: Uint8List(1),
        ),
      );
      await pumpEventQueue();
      owner.preload('image', null, 'comic', 'chapter');
      expect(loads, 3);
      await owner.dispose();
      for (final source in sources) {
        await source.close();
      }
    },
  );
}
