import 'dart:async';
import 'dart:io';
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

  test(
    'at most two downloads run and cancellation leaves queued samples untouched',
    () async {
      final streams = <StreamController<ImageDownloadProgress>>[];
      var active = 0;
      var peak = 0;
      ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) {
        final stream = StreamController<ImageDownloadProgress>(
          onListen: () {
            active++;
            if (active > peak) peak = active;
          },
          onCancel: () => active--,
        );
        streams.add(stream);
        return stream.stream;
      };
      final probe = ComicLayoutProbe();
      final pending = detect(probe);
      await pumpEventQueue();
      expect(streams, hasLength(2));
      expect(active, 2);
      streams.first.add(
        ImageDownloadProgress(
          currentBytes: page.length,
          totalBytes: page.length,
          imageBytes: page,
        ),
      );
      await pumpEventQueue();
      expect(streams, hasLength(3));
      expect(peak, 2);
      probe.cancel();
      final result = await pending;
      await pumpEventQueue();
      expect(result.layout, ComicLayout.unknown);
      expect(active, 0);
      expect(streams, hasLength(3));
      for (final stream in streams) {
        await stream.close();
      }
    },
  );

  test(
    'local reads share the two-task limit and late reads cannot restart the queue',
    () async {
      final reads = <Completer<Uint8List>>[];
      await IOOverrides.runZoned(() async {
        final probe = ComicLayoutProbe();
        final pending = detect(
          probe,
          List.generate(7, (i) => 'file:///scan-$i.png'),
        );
        await pumpEventQueue();
        expect(reads, hasLength(2));
        probe.cancel();
        expect((await pending).layout, ComicLayout.unknown);
        for (final read in reads) {
          read.complete(page);
        }
        await pumpEventQueue();
        expect(reads, hasLength(2));
      }, createFile: (path) => _PendingFile(path, page.length, reads));
    },
  );

  test('timeout releases every download subscription', () async {
    var cancellations = 0;
    ImageDownloader.debugLoadComicImageUnwrapped = (_, _, _, _) =>
        StreamController<ImageDownloadProgress>(
          onCancel: () => cancellations++,
        ).stream;
    final result = await detect(ComicLayoutProbe());
    expect(result.layout, ComicLayout.unknown);
    expect(cancellations, 2);
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
      expect(cancellations, 2);
      probe.cancel();
      expect(cancellations, 2);
    },
  );
}

class _PendingFile extends Fake implements File {
  _PendingFile(this.path, this.size, this.reads);
  @override
  final String path;
  final int size;
  final List<Completer<Uint8List>> reads;
  @override
  Future<int> length() async => size;
  @override
  Future<Uint8List> readAsBytes() {
    final read = Completer<Uint8List>();
    reads.add(read);
    return read.future;
  }
}
