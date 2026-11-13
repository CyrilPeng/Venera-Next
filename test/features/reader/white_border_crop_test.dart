import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/white_border_crop.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_settings.dart';

img.Image _page({
  int width = 100,
  int height = 160,
  int left = 10,
  int right = 12,
}) {
  final page = img.Image(width: width, height: height, numChannels: 4);
  img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
  img.fillRect(
    page,
    x1: left,
    y1: 0,
    x2: width - right - 1,
    y2: height - 1,
    color: img.ColorRgba8(32, 64, 96, 255),
  );
  return page;
}

(int, int) _insets(img.Image page) => horizontalWhiteBorderInsets(
  page.getBytes(order: img.ChannelOrder.rgba),
  page.width,
  page.height,
);

Future<ui.Image> _decode(img.Image page) async {
  final codec = await ui.instantiateImageCodec(img.encodePng(page));
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

class _Readbacks {
  final gate = Completer<void>();
  int reads = 0, clones = 0, disposed = 0;
}

class _GatedImage extends Fake implements ui.Image {
  _GatedImage(this.pixels, this.readbacks);
  final ui.Image pixels;
  final _Readbacks readbacks;

  @override
  int get width => pixels.width;
  @override
  int get height => pixels.height;
  @override
  ui.Image clone() {
    readbacks.clones++;
    return _GatedImage(pixels.clone(), readbacks);
  }

  @override
  Future<ByteData?> toByteData({
    ui.ImageByteFormat format = ui.ImageByteFormat.rawRgba,
  }) async {
    readbacks.reads++;
    await readbacks.gate.future;
    return pixels.toByteData(format: format);
  }

  @override
  void dispose() {
    readbacks.disposed++;
    pixels.dispose();
  }
}

class _Provider extends ReaderImageProvider {
  _Provider(img.Image page)
    : bytes = img.encodePng(page),
      super('crop-${_next++}', null, 'comic', 'chapter', 1);
  static int _next = 0;
  Uint8List bytes;
  int loads = 0;
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    loads++;
    checkStop();
    return bytes;
  }
}

class _DeferredCrop extends ReaderWhiteBorderCrop {
  _DeferredCrop(super.work);
  final results = <Completer<ui.Rect?>>[];
  int calls = 0;
  @override
  Future<ui.Rect?> detect(ui.Image image, Object identity) {
    calls++;
    return results.isEmpty
        ? super.detect(image, identity)
        : results.removeAt(0).future;
  }
}

class _OversizeImage extends Fake implements ui.Image {
  @override
  int get width => 4096;
  @override
  int get height => 4096;
  @override
  ui.Image clone() => throw StateError('An oversized image must not be copied');
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
  await tester.pump();
}

Future<img.Image> _snapshot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final result = await tester.runAsync(() async {
    final frame = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final output = Directory('build/issues-ui-qa')
        ..createSync(recursive: true);
      File('${output.path}/$name.png').writeAsBytesSync(bytes);
      return img.decodePng(bytes)!;
    } finally {
      frame.dispose();
    }
  });
  return result!;
}

Widget _view(
  ImageProvider provider,
  ReaderWhiteBorderCrop? crop,
  GlobalKey repaint, {
  bool split = false,
  bool invert = false,
  bool dimensions = false,
  BoxFit? fit = BoxFit.contain,
  double? height,
}) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 164,
      height: height,
      child: RepaintBoundary(
        key: repaint,
        child: ComicImage(
          image: provider,
          width: double.infinity,
          height: height,
          whiteBorderCrop: crop,
          splitWideImage: split,
          splitWideImageInvert: invert,
          showImageDimensions: dimensions,
          fit: fit,
          filterQuality: FilterQuality.none,
        ),
      ),
    ),
  ),
);

void _cleanup(WidgetTester tester, ReaderWhiteBorderCrop crop, ImageWork work) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    crop.dispose();
    var closed = false;
    final closing = work.dispose().then((_) => closed = true);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await tester.pump();
    await _waitUntil(tester, () => closed);
    await closing;
    ComicImage.clear();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'images beyond the readback budget remain full without retaining pixels',
    () async {
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      var tasks = 0;
      work.retainTasks((_) {
        tasks++;
        return () {};
      });
      try {
        expect(
          await crop.detect(_OversizeImage(), 'large'),
          const Rect.fromLTWH(0, 0, 4096, 4096),
        );
        expect(tasks, 0);
      } finally {
        crop.dispose();
        await work.dispose();
      }
    },
  );

  test(
    'failed pixel readback keeps the full page and releases its image handle',
    () async {
      final pixels = await _decode(_page());
      final reads = _Readbacks();
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      try {
        final detecting = crop.detect(
          _GatedImage(pixels, reads),
          'unavailable',
        );
        await pumpEventQueue();
        reads.gate.completeError(StateError('Pixel readback failed'));
        expect(await detecting, const Rect.fromLTWH(0, 0, 100, 160));
        expect(reads.disposed, 1);
        expect(pixels.debugDisposed, isFalse);
        (await work.prepareForExit())();
      } finally {
        if (!reads.gate.isCompleted) reads.gate.complete();
        crop.dispose();
        await work.dispose();
        pixels.dispose();
      }
    },
  );

  testWidgets(
    'a fresh decode with the same address and dimensions never reuses old bounds',
    (tester) async {
      final source = _Provider(_page());
      final work = ImageWork();
      final crop = _DeferredCrop(work);
      final repaint = GlobalKey();
      _cleanup(tester, crop, work);
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(source, work), crop, repaint),
      );
      await _waitUntil(
        tester,
        () => (tester.getSize(find.byKey(repaint)).height - 320).abs() < 0.01,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      source.bytes = img.encodePng(_page(left: 0, right: 0));
      await tester.runAsync(() => source.evict());
      await tester.pump();
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(source, work), crop, repaint),
      );
      await _waitUntil(tester, () => crop.calls >= 2);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(tester.getSize(find.byKey(repaint)).height, closeTo(262.4, 0.01));
      expect(find.byType(RawImage), findsOneWidget);
      expect(source.loads, 2);
    },
  );

  test('white margins retain a buffer without removing any content rows', () {
    expect(_insets(_page()), (8, 10));
    expect(_insets(_page(left: 0, right: 12)), (0, 10));
    expect(_insets(_page(left: 10, right: 0)), (8, 0));
  });

  test(
    'a full crop queue bounds retained images and signals space for a retry',
    () async {
      final pixels = await _decode(_page());
      final reads = _Readbacks();
      final image = _GatedImage(pixels, reads);
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      var notifications = 0;
      crop.addListener(() => notifications++);
      try {
        final accepted = [for (var i = 0; i < 4; i++) crop.detect(image, i)];
        expect(await crop.detect(image, 'overflow'), isNull);
        expect(reads.clones, 4);
        reads.gate.complete();
        expect(
          await Future.wait(accepted),
          everyElement(const Rect.fromLTWH(8, 0, 82, 160)),
        );
        expect(notifications, greaterThanOrEqualTo(1));
        expect(
          await crop.detect(image, 'overflow'),
          const Rect.fromLTWH(8, 0, 82, 160),
        );
        expect(reads.disposed, 5);
      } finally {
        if (!reads.gate.isCompleted) reads.gate.complete();
        crop.dispose();
        await work.dispose();
        pixels.dispose();
      }
    },
  );

  test(
    'a single edge text pixel or pale panel stops that edge at every row',
    () {
      for (final row in [0, 79, 159]) {
        final page = _page();
        page.setPixelRgba(2, row, 0, 0, 0, 255);
        expect(_insets(page), (0, 10));
        page.setPixelRgba(2, row, 252, 252, 252, 255);
        expect(_insets(page), (0, 10));
      }
    },
  );

  test('blank pages, tiny margins and oversized margins stay intact', () {
    final blank = img.Image(width: 100, height: 100, numChannels: 4);
    img.fill(blank, color: img.ColorRgba8(255, 255, 255, 255));
    expect(_insets(blank), (0, 0));
    expect(_insets(_page(left: 3, right: 3)), (0, 0));
    expect(_insets(_page(left: 26, right: 26)), (0, 0));
    expect(horizontalWhiteBorderInsets(Uint8List(16), 100, 160), (0, 0));
    expect(horizontalWhiteBorderInsets(Uint8List(16), -1, 160), (0, 0));
  });

  test(
    'transparent empty edges qualify but partially transparent ink stays',
    () {
      final page = _page();
      for (var y = 0; y < page.height; y++) {
        for (var x = 0; x < 10; x++) {
          page.setPixelRgba(x, y, 0, 0, 0, 0);
        }
      }
      expect(_insets(page), (8, 10));
      page.setPixelRgba(1, 100, 255, 255, 255, 128);
      expect(_insets(page), (0, 10));
    },
  );

  test(
    'queued readbacks drain after cancellation, then resume and share cached bounds',
    () async {
      final pixels = await _decode(_page());
      final reads = _Readbacks();
      final image = _GatedImage(pixels, reads);
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      final tasks = <ImageWorkTask>[];
      work.retainTasks((task) {
        tasks.add(task);
        return () {};
      });
      addTearDown(() async {
        if (!reads.gate.isCompleted) reads.gate.complete();
        crop.dispose();
        await work.dispose();
        pixels.dispose();
      });
      final first = crop.detect(image, 'a');
      expect(identical(first, crop.detect(image, 'a')), isTrue);
      final second = crop.detect(image, 'b');
      await pumpEventQueue();
      expect(reads.reads, 1);
      expect(reads.clones, 2);
      var drained = false;
      final preparing = work.prepareForExit().then((release) {
        drained = true;
        return release;
      });
      await pumpEventQueue();
      expect(drained, isFalse);
      expect(reads.disposed, 0);
      reads.gate.complete();
      expect(await first, isNull);
      expect(await second, isNull);
      final release = await preparing;
      expect(reads.disposed, 2);
      expect(reads.reads, 1);
      release();
      final rect = await crop.detect(image, 'a');
      expect(rect, const Rect.fromLTWH(8, 0, 82, 160));
      expect(await crop.detect(image, 'a'), rect);
      expect(tasks, hasLength(3));
      expect(reads.reads, 2);
      expect(reads.disposed, 3);
      expect(pixels.debugDisposed, isFalse);
    },
  );

  test(
    'disposing a crop owner waits for its retained readback to finish',
    () async {
      final pixels = await _decode(_page());
      final reads = _Readbacks();
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      addTearDown(() async {
        if (!reads.gate.isCompleted) reads.gate.complete();
        await work.dispose();
        pixels.dispose();
      });
      final pending = crop.detect(_GatedImage(pixels, reads), 'closing');
      await pumpEventQueue();
      crop.dispose();
      var closed = false;
      final closing = work.dispose().then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(reads.disposed, 0);
      reads.gate.complete();
      expect(await pending, isNull);
      await closing;
      expect(reads.disposed, 1);
    },
  );

  test(
    'crop preference defaults off and keeps global, device and comic precedence',
    () {
      expect(ReaderSettings.resolve(global: {}).cropWhiteBorders, isFalse);
      expect(
        ReaderSettings.resolve(
          global: {'cropWhiteBorders': true},
        ).cropWhiteBorders,
        isTrue,
      );
      expect(
        ReaderSettings.resolve(
          global: {'cropWhiteBorders': true},
          device: {'enabled': true, 'cropWhiteBorders': false},
        ).cropWhiteBorders,
        isFalse,
      );
      expect(
        ReaderSettings.resolve(
          global: {},
          device: {'enabled': true, 'cropWhiteBorders': false},
          comic: {'enabled': true, 'cropWhiteBorders': true},
        ).cropWhiteBorders,
        isTrue,
      );
    },
  );

  testWidgets(
    'cropped geometry and pixels restore without another download or changed original',
    (tester) async {
      final source = _Provider(_page());
      final original = Uint8List.fromList(source.bytes);
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      final display = ReaderDisplayImageProvider(source, work);
      final repaint = GlobalKey();
      _cleanup(tester, crop, work);
      await tester.pumpWidget(_view(display, crop, repaint, dimensions: true));
      await _waitUntil(
        tester,
        () =>
            find.text('100 × 160').evaluate().isNotEmpty &&
            (tester.getSize(find.byKey(repaint)).height - 320).abs() < 0.01,
      );
      expect(source.loads, 1);
      expect(find.text('82 × 160'), findsNothing);
      await tester.pumpWidget(_view(display, crop, repaint));
      final cropped = await _snapshot(tester, repaint, 'white-border-cropped');
      expect(cropped.getPixel(0, 100).r, 255);
      expect(cropped.getPixel(8, 100).r, 32);
      await tester.pumpWidget(_view(display, null, repaint));
      expect(tester.getSize(find.byKey(repaint)).height, closeTo(262.4, 0.01));
      final full = await _snapshot(tester, repaint, 'white-border-original');
      expect(full.getPixel(8, 100).r, 255);
      expect(full.getPixel(20, 100).r, 32);
      await tester.pumpWidget(_view(display, crop, repaint));
      await _waitUntil(
        tester,
        () => (tester.getSize(find.byKey(repaint)).height - 320).abs() < 0.01,
      );
      expect(source.loads, 1);
      expect(source.bytes, orderedEquals(original));
      expect(
        PaintingBinding.instance.imageCache.statusForKey(source).keepAlive,
        isTrue,
      );
    },
  );

  testWidgets(
    'cropping preserves a spread center, split order and invert order',
    (tester) async {
      final page = _page(width: 200, height: 80, left: 20, right: 40);
      img.fillRect(
        page,
        x1: 20,
        y1: 0,
        x2: 99,
        y2: 79,
        color: img.ColorRgba8(220, 0, 0, 255),
      );
      img.fillRect(
        page,
        x1: 100,
        y1: 0,
        x2: 159,
        y2: 79,
        color: img.ColorRgba8(0, 0, 220, 255),
      );
      final source = _Provider(page);
      final work = ImageWork();
      final crop = ReaderWhiteBorderCrop(work);
      final display = ReaderDisplayImageProvider(source, work);
      final repaint = GlobalKey();
      _cleanup(tester, crop, work);
      await tester.pumpWidget(_view(display, crop, repaint, split: true));
      await _waitUntil(
        tester,
        () => (tester.getSize(find.byKey(repaint)).height - 320).abs() < 0.01,
      );
      final normal = await _snapshot(tester, repaint, 'white-border-split');
      expect(normal.getPixel(82, 80).b, 220);
      expect(normal.getPixel(82, 240).r, 220);
      await tester.pumpWidget(
        _view(display, crop, repaint, split: true, invert: true),
      );
      final inverted = await _snapshot(
        tester,
        repaint,
        'white-border-split-inverted',
      );
      expect(inverted.getPixel(82, 80).r, 220);
      expect(inverted.getPixel(82, 240).b, 220);
    },
  );

  testWidgets(
    'a late crop cannot change a replacement image or reenable a disabled setting',
    (tester) async {
      final first = _Provider(_page());
      final second = _Provider(_page(height: 80));
      final work = ImageWork();
      final crop = _DeferredCrop(work);
      final a = Completer<Rect?>(), b = Completer<Rect?>();
      crop.results.addAll([a, b]);
      final repaint = GlobalKey();
      _cleanup(tester, crop, work);
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(first, work), crop, repaint),
      );
      await _waitUntil(tester, () => crop.calls == 1);
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(second, work), crop, repaint),
      );
      await _waitUntil(tester, () => crop.calls == 2);
      a.complete(const Rect.fromLTWH(8, 0, 82, 160));
      await tester.pump();
      expect(tester.getSize(find.byKey(repaint)).height, closeTo(131.2, 0.01));
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(second, work), null, repaint),
      );
      b.complete(const Rect.fromLTWH(10, 0, 80, 80));
      await tester.pump();
      expect(tester.getSize(find.byKey(repaint)).height, closeTo(131.2, 0.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a cancelled scan settling after resume retries the same mounted still image',
    (tester) async {
      final source = _Provider(_page());
      final work = ImageWork();
      final crop = _DeferredCrop(work);
      final pending = Completer<Rect?>();
      crop.results.add(pending);
      final repaint = GlobalKey();
      _cleanup(tester, crop, work);
      await tester.pumpWidget(
        _view(ReaderDisplayImageProvider(source, work), crop, repaint),
      );
      await _waitUntil(tester, () => crop.calls == 1);
      work.holdForExit()();
      pending.complete();
      await _waitUntil(
        tester,
        () => (tester.getSize(find.byKey(repaint)).height - 320).abs() < 0.01,
      );
      expect(crop.calls, greaterThanOrEqualTo(2));
      expect(source.loads, 1);
    },
  );

  testWidgets('animated images retain full geometry from the first frame', (
    tester,
  ) async {
    final page = _page();
    page.addFrame(_page(left: 0, right: 0));
    for (final frame in page.frames) {
      frame.frameDuration = 100;
    }
    // Use GIF bytes so the real codec declares animation before delivery.
    final animated = _AnimatedProvider(img.encodeGif(page));
    final work = ImageWork();
    final crop = _DeferredCrop(work);
    final repaint = GlobalKey();
    _cleanup(tester, crop, work);
    await tester.pumpWidget(
      _view(ReaderDisplayImageProvider(animated, work), crop, repaint),
    );
    await _waitUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
    expect(tester.getSize(find.byKey(repaint)).height, closeTo(262.4, 0.01));
    await tester.pump(const Duration(milliseconds: 150));
    expect(crop.calls, 0);
    expect(tester.getSize(find.byKey(repaint)).height, closeTo(262.4, 0.01));
  });
}

class _AnimatedProvider extends ReaderImageProvider {
  _AnimatedProvider(this.bytes)
    : super('crop-animation', null, 'comic', 'chapter', 1);
  final Uint8List bytes;
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async => bytes;
}
