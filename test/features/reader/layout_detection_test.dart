import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_next/features/reader/layout_detection.dart';
import 'package:venera_next/foundation/comic_layout.dart';
import 'package:venera_next/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final page = image.encodePng(image.Image(width: 20, height: 30));
  final strip = image.encodePng(image.Image(width: 20, height: 80));
  final images = List.generate(9, (i) => 'https://example.invalid/$i.png');
  Future<ComicLayoutDetection> detect(
    ComicLayoutProbe probe, [
    List<String>? urls,
  ]) => probe.detect(
    images: urls ?? images,
    sourceKey: 'source',
    comicId: 'comic',
    chapterId: 'chapter',
  );
  Stream<ImageDownloadProgress> bytes(Uint8List data) => Stream.value(
    ImageDownloadProgress(
      currentBytes: data.length,
      totalBytes: data.length,
      imageBytes: data,
    ),
  );
  tearDown(() {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.debugLoadComicImageUnwrapped = null;
  });

  test(
    'skips cover, samples six originals and forwards comic identity',
    () async {
      final loaded = <String>[];
      ImageDownloader.debugLoadComicImageUnwrapped =
          (url, source, comic, chapter) {
            expect((source, comic, chapter), ('source', 'comic', 'chapter'));
            loaded.add(url);
            return bytes(page);
          };
      final result = await detect(ComicLayoutProbe());
      expect(result.layout, ComicLayout.paged);
      expect(result.sampleCount, 6);
      expect(loaded, images.sublist(1, 7));
    },
  );

  test('fewer than four body images do not start downloads', () async {
    ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) =>
        throw StateError('Unexpected download');
    expect(
      (await detect(ComicLayoutProbe(), images.take(4).toList())).layout,
      ComicLayout.unknown,
    );
  });

  test(
    'failed and corrupt samples do not prevent classification from valid originals',
    () async {
      ImageDownloader.debugLoadComicImageUnwrapped = (url, _, _, _) {
        if (url == images[1]) return Stream.error(StateError('offline'));
        if (url == images[2]) return bytes(Uint8List.fromList([1, 2, 3]));
        return bytes(strip);
      };
      final result = await detect(ComicLayoutProbe());
      expect(result.layout, ComicLayout.longStrip);
      expect(result.sampleCount, 4);
    },
  );

  test('all failed downloads fall back to unknown', () async {
    ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) =>
        Stream.error(StateError('offline'));
    final result = await detect(ComicLayoutProbe());
    expect(result.layout, ComicLayout.unknown);
    expect(result.sampleCount, 0);
  });

  test('timeout releases every download subscription', () async {
    var cancellations = 0;
    ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) =>
        StreamController<ImageDownloadProgress>(
          onCancel: () => cancellations++,
        ).stream;
    final result = await detect(ComicLayoutProbe());
    expect(result.layout, ComicLayout.unknown);
    expect(cancellations, 6);
  });

  test(
    'cancel stops all active downloads without waiting for timeout',
    () async {
      var cancellations = 0;
      ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) =>
          StreamController<ImageDownloadProgress>(
            onCancel: () => cancellations++,
          ).stream;
      final probe = ComicLayoutProbe();
      final pending = detect(probe);
      await pumpEventQueue();
      probe.cancel();
      final result = await pending;
      expect(result.layout, ComicLayout.unknown);
      expect(cancellations, 6);
      probe.cancel();
      expect(cancellations, 6);
    },
  );
}
