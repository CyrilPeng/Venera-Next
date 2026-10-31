import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/image_work.dart';

class _Provider extends ReaderImageProvider {
  _Provider(this.bytes)
    : super('scroll-${_next++}', null, 'comic', 'chapter', 1);

  static int _next = 0;
  final Future<Uint8List> bytes;
  int loads = 0;
  int decodes = 0;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    loads++;
    checkStop();
    return bytes;
  }

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, (buffer, {getTargetSize}) {
    decodes++;
    return decode(buffer, getTargetSize: getTargetSize);
  });
}

// Exercise Flutter's fast-scroll policy deterministically, not device FPS.
class _ScrollPolicy extends ScrollPhysics {
  const _ScrollPolicy({required this.shouldDefer, super.parent});

  final bool Function() shouldDefer;

  @override
  _ScrollPolicy applyTo(ScrollPhysics? ancestor) =>
      _ScrollPolicy(shouldDefer: shouldDefer, parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => shouldDefer();
}

class _Fixture {
  _Fixture(Future<Uint8List> bytes) : source = _Provider(bytes);

  final _Provider source;
  final work = ImageWork();
  late final display = ReaderDisplayImageProvider(source, work);
  bool defer = false;
  final cache = PaintingBinding.instance.imageCache;

  Future<void> mount(
    WidgetTester tester, {
    required bool comic,
    bool direct = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          physics: _ScrollPolicy(shouldDefer: () => defer),
          children: [
            SizedBox(
              width: 64,
              height: 96,
              child: comic
                  ? ComicImage(image: direct ? source : display)
                  : Image(image: direct ? source : display),
            ),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    ),
  );

  ui.Image? frame(WidgetTester tester) {
    final raw = find.byType(RawImage);
    return raw.evaluate().isEmpty ? null : tester.widget<RawImage>(raw).image;
  }

  Future<void> waitForFrame(WidgetTester tester) async {
    for (var i = 0; i < 80 && frame(tester) == null; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
    }
    expect(frame(tester), isNotNull);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  Future<void> warm(WidgetTester tester) async {
    await mount(tester, comic: false, direct: true);
    await waitForFrame(tester);
    await unmount(tester);
    expect(cache.statusForKey(source).keepAlive, isTrue);
    expect(source.loads, 1);
    expect(source.decodes, 1);
  }

  Future<void> dispose(WidgetTester tester) async {
    defer = false;
    await unmount(tester);
    final closing = work.dispose();
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
    await tester.runAsync(() => closing);
    ComicImage.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pixels = img.Image(width: 32, height: 48);
  final fixtures = {
    'png': img.encodePng(pixels),
    'jpeg': img.encodeJpg(pixels),
  };

  for (final comic in [false, true]) {
    final consumer = comic ? 'ComicImage' : 'Image';
    for (final entry in fixtures.entries) {
      testWidgets(
        '$consumer displays cached ${entry.key} during fast scrolling without another decode',
        (tester) async {
          final fixture = _Fixture(Future.value(entry.value));
          final maximumBytes = fixture.cache.maximumSizeBytes;
          try {
            await fixture.warm(tester);
            fixture.defer = true;
            // A direct provider is the control: Flutter already sees its cache.
            await fixture.mount(tester, comic: comic, direct: true);
            await tester.pump();
            expect(fixture.frame(tester), isNotNull);
            await fixture.unmount(tester);

            await fixture.mount(tester, comic: comic);
            await tester.pump();
            expect(
              fixture.frame(tester),
              isNotNull,
              reason: 'The relay must expose the underlying decoded cache hit',
            );
            expect(fixture.source.loads, 1);
            expect(fixture.source.decodes, 1);
            expect(fixture.cache.containsKey(fixture.display), isFalse);
            expect(fixture.cache.currentSize, 1);
            expect(fixture.cache.maximumSizeBytes, maximumBytes);
          } finally {
            await fixture.dispose(tester);
          }
        },
      );
    }

    testWidgets('$consumer still defers a cold image until scrolling slows', (
      tester,
    ) async {
      final fixture = _Fixture(Future.value(fixtures['png']!));
      try {
        fixture.defer = true;
        await fixture.mount(tester, comic: comic);
        await tester.pump(const Duration(milliseconds: 16));
        expect(fixture.frame(tester), isNull);
        expect(fixture.source.loads, 0);
        expect(fixture.source.decodes, 0);
        fixture.defer = false;
        await tester.pump();
        await fixture.waitForFrame(tester);
        expect(fixture.source.loads, 1);
      } finally {
        await fixture.dispose(tester);
      }
    });

    testWidgets(
      '$consumer joins an existing pending image while scrolling fast',
      (tester) async {
        final bytes = Completer<Uint8List>();
        final fixture = _Fixture(bytes.future);
        final stream = fixture.source.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((info, _) => info.dispose());
        stream.addListener(listener);
        try {
          expect(fixture.cache.statusForKey(fixture.source).pending, isTrue);
          fixture.defer = true;
          await fixture.mount(tester, comic: comic);
          bytes.complete(fixtures['png']!);
          await fixture.waitForFrame(tester);
          expect(fixture.source.loads, 1);
          expect(fixture.source.decodes, 1);
        } finally {
          if (!bytes.isCompleted) bytes.complete(fixtures['png']!);
          stream.removeListener(listener);
          await fixture.dispose(tester);
        }
      },
    );

    testWidgets('$consumer cached image still respects reading-session holds', (
      tester,
    ) async {
      final fixture = _Fixture(Future.value(fixtures['png']!));
      final release = fixture.work.holdForExit();
      try {
        await fixture.warm(tester);
        fixture.defer = true;
        await fixture.mount(tester, comic: comic);
        await tester.pump();
        expect(fixture.frame(tester), isNull);
        release();
        await tester.pump();
        expect(fixture.frame(tester), isNotNull);
        expect(fixture.source.loads, 1);
        expect(fixture.source.decodes, 1);
      } finally {
        release();
        await fixture.dispose(tester);
      }
    });

    testWidgets(
      '$consumer removed during fast scrolling never starts its load',
      (tester) async {
        final fixture = _Fixture(Future.value(fixtures['png']!));
        try {
          fixture.defer = true;
          await fixture.mount(tester, comic: comic);
          await fixture.unmount(tester);
          fixture.defer = false;
          await tester.pump();
          expect(fixture.source.loads, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }
}
