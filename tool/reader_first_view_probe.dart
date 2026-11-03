// Host scheduling experiment, not Android frame pacing or runtime acceptance.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_next/features/reader/comic_image.dart';
import 'package:venera_next/features/reader/display_image_provider.dart';
import 'package:venera_next/features/reader/image_precache.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/reader_diagnostics.dart';

const _width = int.fromEnvironment(
  'READER_FIRST_VIEW_WIDTH',
  defaultValue: 1500,
);
const _height = int.fromEnvironment(
  'READER_FIRST_VIEW_HEIGHT',
  defaultValue: 2400,
);
const _runs = int.fromEnvironment('READER_FIRST_VIEW_RUNS', defaultValue: 5);
const _delayMs = int.fromEnvironment(
  'READER_FIRST_VIEW_DELAY_MS',
  defaultValue: 120,
);
const _output = String.fromEnvironment(
  'READER_FIRST_VIEW_OUTPUT',
  defaultValue: 'build/reader-first-view-probe/report.json',
);

class _Provider extends ReaderImageProvider {
  _Provider(this.bytes, this.mark, ReaderDiagnostics diagnostics)
    : super(
        'first-view-${_next++}',
        null,
        'synthetic',
        'chapter',
        1,
        diagnostics: diagnostics,
      );
  static int _next = 0;
  final Uint8List bytes;
  final void Function(String) mark;
  int loads = 0, decodes = 0;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    checkStop();
    loads++;
    mark('encodedRead');
    return Future.value(bytes);
  }

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, (buffer, {getTargetSize}) async {
    decodes++;
    mark('codecRequested');
    final codec = await decode(buffer, getTargetSize: getTargetSize);
    mark('codecReady');
    return codec;
  });
}

class _ScrollPolicy extends ScrollPhysics {
  const _ScrollPolicy(this.defer, {super.parent});
  final bool Function() defer;
  @override
  _ScrollPolicy applyTo(ScrollPhysics? ancestor) =>
      _ScrollPolicy(defer, parent: buildParent(ancestor));
  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => defer();
}

class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ObservePaint(onPaint);
  @override
  void updateRenderObject(BuildContext context, _ObservePaint renderObject) =>
      renderObject.onPaint = onPaint;
}

class _ObservePaint extends RenderProxyBox {
  _ObservePaint(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}

Future<Map<String, Object>> _measure(
  WidgetTester tester,
  Uint8List bytes,
  String mode,
) async {
  final clock = Stopwatch()..start();
  final marks = <String, int>{};
  void mark(String name) =>
      marks.putIfAbsent(name, () => clock.elapsedMicroseconds);
  final diagnostics = ReaderDiagnostics(
    nowMicros: () => clock.elapsedMicroseconds,
  );
  final work = ImageWork(diagnostics: diagnostics);
  final precache = ReaderImagePrecache(work: work);
  final source = _Provider(bytes, mark, diagnostics);
  final display = ReaderDisplayImageProvider(source, work);
  final cache = PaintingBinding.instance.imageCache;
  var maxRss = ProcessInfo.currentRss;
  var maxDecodedBytes = cache.currentSizeBytes;
  final pumps = <int>[];
  void sampleMemory() {
    maxRss = math.max(maxRss, ProcessInfo.currentRss);
    maxDecodedBytes = math.max(maxDecodedBytes, cache.currentSizeBytes);
  }

  Future<void> pump() async {
    final timer = Stopwatch()..start();
    await tester.pump();
    pumps.add(timer.elapsedMicroseconds);
    sampleMemory();
  }

  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 160 && !ready(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await pump();
    }
    expect(ready(), isTrue);
  }

  ComicImageState? consumer;
  var defer = true;
  final cacheLimit = cache.maximumSizeBytes;
  try {
    diagnostics.start(
      mode: ReaderDiagnosticMode.continuous,
      processingEnabled: false,
      appVersion: '0.0.0',
      refreshRate: 120,
    );
    if (mode == 'decodedNext') {
      mark('predecodeRequested');
      precache.preload(source, ImageConfiguration.empty);
      await until(() => cache.statusForKey(source).keepAlive);
      mark('predecodeReady');
      await pump();
    }
    final beforeDisplayBytes = cache.currentSizeBytes;
    mark('viewRequested');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            physics: _ScrollPolicy(() {
              if (defer) mark('scrollDeferred');
              return defer;
            }),
            children: [
              _PaintObserver(
                onPaint: () => mark(
                  consumer?.readyForAutoReading == true
                      ? 'imagePaintSubmitted'
                      : 'placeholderPaintSubmitted',
                ),
                child: SizedBox(
                  width: 360,
                  height: 576,
                  child: ComicImage(
                    image: display,
                    fit: BoxFit.contain,
                    onInit: (state) => consumer = state as ComicImageState,
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await pump();
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: _delayMs)),
    );
    await pump();
    final paintedBeforeRelease = marks.containsKey('imagePaintSubmitted');
    if (mode == 'decodedNext') {
      expect(paintedBeforeRelease, isTrue);
    } else {
      expect(paintedBeforeRelease, isFalse);
      expect(source.loads, 0);
      expect(source.decodes, 0);
    }
    defer = false;
    mark('scrollReleased');
    await pump();
    await until(() => marks.containsKey('imagePaintSubmitted'));
    expect(source.loads, 1);
    expect(source.decodes, 1);
    expect(cache.maximumSizeBytes, cacheLimit);
    final report = jsonDecode(diagnostics.exportJson()) as Map;
    return {
      'mode': mode,
      'timestampsUs': Map.of(marks),
      'viewToPaintUs': marks['imagePaintSubmitted']! - marks['viewRequested']!,
      'paintedBeforeScrollRelease': paintedBeforeRelease,
      'loads': source.loads,
      'decodes': source.decodes,
      'decodedCacheBeforeDisplayBytes': beforeDisplayBytes,
      'sampledDecodedCacheMaxBytes': maxDecodedBytes,
      'sampledProcessRssMaxBytes': maxRss,
      'testPumpWallUs': pumps,
      'imageStages': report['imageEvents'] as List,
      'hostFrameTimingSamples': report['retainedFrameSamples'] as Map,
    };
  } finally {
    defer = false;
    await tester.pumpWidget(const SizedBox());
    final closing = precache.dispose();
    await tester.pump();
    await tester.runAsync(() => closing);
    cache.clear();
    cache.clearLiveImages();
    await tester.pump();
    await tester.runAsync(work.dispose);
    diagnostics.dispose();
    ComicImage.clear();
    // ignore: invalid_use_of_visible_for_testing_member
    expect(BaseImageProvider.debugActiveLoadCount, 0);
  }
}

void main() {
  testWidgets(
    'encoded-only versus one decoded neighbour, A/B/A',
    (tester) async {
      expect(_width, inInclusiveRange(1, 4096));
      expect(_height, inInclusiveRange(1, 4096));
      expect(_runs, inInclusiveRange(1, 12));
      expect(_delayMs, inInclusiveRange(1, 1000));
      final pixels = img.Image(width: _width, height: _height);
      for (var y = 0; y < _height; y++) {
        for (var x = 0; x < _width; x++) {
          pixels.setPixelRgb(
            x,
            y,
            (x * 3 + y * 5) & 255,
            (x ~/ 3 + y * 7) & 255,
            (x * 11 + y ~/ 5) & 255,
          );
        }
      }
      final groups = <Map<String, Object>>[];
      for (final input in {
        'png': img.encodePng(pixels),
        'jpeg': img.encodeJpg(pixels, quality: 90),
      }.entries) {
        final digest = sha256.convert(input.value).toString();
        final samples = <Map<String, Object>>[];
        for (var run = 0; run <= _runs; run++) {
          for (final mode in [
            'encodedOnlyA1',
            'decodedNext',
            'encodedOnlyA2',
          ]) {
            final result = await _measure(tester, input.value, mode);
            if (run != 0) samples.add({'round': run, ...result});
          }
        }
        expect(sha256.convert(input.value).toString(), digest);
        groups.add({
          'format': input.key,
          'encodedBytes': input.value.length,
          'sha256': digest,
          'samples': samples,
        });
      }
      final report = {
        'schema': 1,
        'revision': const String.fromEnvironment(
          'READER_FIRST_VIEW_REVISION',
          defaultValue: 'working-tree',
        ),
        'platform': Platform.operatingSystem,
        'dartVersion': Platform.version,
        'width': _width,
        'height': _height,
        'controlledScrollDeferralMs': _delayMs,
        'runsAfterWarmup': _runs,
        'limitations': [
          'Synthetic encoded memory, no private content, file or network I/O.',
          'One predecoded image; no production settings, scheduling or cache-limit changes.',
          'Paint submission is a UI paint traversal, not GPU completion or screen presentation.',
          'Pump wall times include the widget-test harness and are not device frame timings.',
          'RSS and decoded bytes are sampled, not a continuous process-memory peak.',
          'Controlled deferral demonstrates scheduling, not the cause or improvement on Android.',
        ],
        'groups': groups,
      };
      await tester.runAsync(() async {
        final file = File(_output);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
