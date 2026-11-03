import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as fixture;
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/reader_settings.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';
import 'package:venera_next/foundation/tv_reader_policy.dart';

class _MemoryImage extends ReaderImageProvider {
  _MemoryImage(this.bytes, {super.decodePixelBudget, super.diagnostics})
    : super('memory', null, 'comic', 'chapter', 1);
  final Uint8List bytes;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    checkStop();
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TV limits are an effective overlay and never rewrite portable settings',
    () {
      final global = <String, Object>{
        'readerMode': 'waterfallTopToBottom',
        'autoReaderMode': true,
        'preloadImageCount': 16,
        'readerScreenPicNumberForLandscape': 3,
      };
      final tv = ReaderSettings.resolve(global: global, tvLowMemory: true);
      expect(tv.readerMode, 'galleryLeftToRight');
      expect(tv.autoReaderMode, isFalse);
      expect(tv.preloadImageCount, 1);
      expect(tv.readerScreenPicNumberForLandscape, 1);
      expect(global['readerMode'], 'waterfallTopToBottom');
      expect(global['preloadImageCount'], 16);
      final ordinary = ReaderSettings.resolve(global: global);
      expect(ordinary.preloadImageCount, 16);
      expect(ordinary.readerScreenPicNumberForLandscape, 3);
      expect(ordinary.autoReaderMode, isTrue);
      final reversed = ReaderSettings.resolve(
        global: const {'readerMode': 'galleryRightToLeft'},
        tvLowMemory: true,
      );
      expect(reversed.readerMode, 'galleryRightToLeft');
    },
  );

  test('decoded dimensions stay bounded without enlarging originals', () {
    for (final dimensions in [
      (64, 32),
      (10000, 8000),
      (1000, 1000000),
      (1000000, 1),
      (1, 1000000),
      (1, 1),
    ]) {
      for (final budget in [32, TvReaderPolicy.decodePixels]) {
        final size = TvReaderPolicy.decodeSize(
          dimensions.$1,
          dimensions.$2,
          pixelBudget: budget,
        );
        expect(size.width * size.height, lessThanOrEqualTo(budget));
        expect(size.width, inInclusiveRange(1, dimensions.$1));
        expect(size.height, inInclusiveRange(1, dimensions.$2));
        expect(size.width, lessThanOrEqualTo(TvReaderPolicy.maximumEdge));
        expect(size.height, lessThanOrEqualTo(TvReaderPolicy.maximumEdge));
      }
    }
  });

  test('decode budgets are part of immutable image-cache identity', () {
    const original = ReaderImageProvider('image', null, 'c', 'e', 1);
    const tv = ReaderImageProvider(
      'image',
      null,
      'c',
      'e',
      1,
      decodePixelBudget: 128,
    );
    expect(original.key, 'image@null@c@e@false');
    expect(original, isNot(tv));
    expect(tv.key, contains('@tv:128'));
  });

  testWidgets(
    'the actual codec keeps TV limits, original dimensions and mainline diagnostics',
    (tester) async {
      final diagnostics = ReaderDiagnostics();
      addTearDown(diagnostics.dispose);
      diagnostics.start(
        mode: ReaderDiagnosticMode.paged,
        processingEnabled: false,
        appVersion: '1.18.2-rc.6',
        refreshRate: 60,
      );
      final png = Uint8List.fromList(
        fixture.encodePng(fixture.Image(width: 64, height: 32)),
      );
      final image = _MemoryImage(
        png,
        decodePixelBudget: 128,
        diagnostics: diagnostics,
      );
      expect(image, _MemoryImage(png, decodePixelBudget: 128));
      final stream = image.resolve(ImageConfiguration.empty);
      final completed = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (info, _) => completed.complete(info),
        onError: completed.completeError,
      );
      stream.addListener(listener);
      for (
        var attempt = 0;
        attempt < 100 && !completed.isCompleted;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed.isCompleted, isTrue);
      final info = await completed.future;
      diagnostics.stop(ReaderDiagnosticStop.review);
      expect(info.image.width * info.image.height, lessThanOrEqualTo(128));
      expect(
        (stream.completer as OriginalImageSize).originalImageSize,
        const ui.Size(64, 32),
      );
      final report = jsonDecode(diagnostics.exportJson()) as Map;
      final stages = (report['imageEvents'] as List).map(
        (event) => event['stage'],
      );
      expect(stages, containsAll(['codecInitWait', 'firstDecodeWait']));
      info.dispose();
      stream.removeListener(listener);
      await image.evict();
      final released = BaseImageProvider.waitForReleasedStream(stream);
      await tester.pump();
      await released;
    },
  );
}
