// Host diagnostic, not a mobile power benchmark. See image_descrambling.zh.md.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_processing.dart' as processing;

const _width = int.fromEnvironment('PIPELINE_WIDTH', defaultValue: 1600);
const _height = int.fromEnvironment('PIPELINE_HEIGHT', defaultValue: 2400);
const _runs = int.fromEnvironment('PIPELINE_RUNS', defaultValue: 3);
const _strips = 16;

String get _script =>
    '''
function modifyImage(image) {
  const output = Image.empty($_width, $_height);
  const height = ${_height ~/ _strips};
  for (let strip = 0; strip < $_strips; strip++) {
    output.fillImageRangeAt(0, strip * height, image,
      0, ($_strips - 1 - strip) * height, $_width, height);
  }
  return output;
}
''';

Uint32List _pixels(String kind) => Uint32List.fromList([
  for (var y = 0; y < _height; y++)
    for (var x = 0; x < _width; x++)
      if (kind == 'monochrome')
        (x % 97 < 3 || y % 113 < 3 || (x ~/ 64 + y ~/ 64) % 7 == 0)
            ? 0xff202020
            : 0xfff8f8f8
      else
        0xff000000 |
            ((x * 3 + y * 5) & 255) |
            (((x ~/ 3 + y * 7) & 255) << 8) |
            (((x * 11 + y ~/ 5) & 255) << 16),
]);

double _ms(Stopwatch clock) => clock.elapsedMicroseconds / 1000;

Future<double> _displayDecode(Uint8List bytes) async {
  final clock = Stopwatch()..start();
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    clock.stop();
    frame.image.dispose();
  } finally {
    codec.dispose();
  }
  return _ms(clock);
}

Future<Map<String, Object>> _measure(
  Uint8List source,
  String initialization,
  Uint32List expected,
) async {
  final decode = Stopwatch()..start();
  final input = await processing.Image.decodeImage(source);
  decode.stop();
  final worker = Stopwatch()..start();
  final script = _script;
  final encoded = await Isolate.run(() async {
    var encodeMs = 0.0;
    final bytes = await processing.runImageScript(
      input,
      script,
      initializationScript: initialization,
      encodeImage: (image) {
        final clock = Stopwatch()..start();
        final result = image.encodePng();
        clock.stop();
        encodeMs = _ms(clock);
        return result;
      },
    );
    return (bytes, encodeMs);
  });
  worker.stop();
  final cachedDecode = await _displayDecode(encoded.$1);

  // Validate every transformed pixel outside the measured phases.
  final restored = await processing.Image.decodeImage(encoded.$1);
  expect((restored.width, restored.height), (_width, _height));
  final stripHeight = _height ~/ _strips;
  for (var i = 0; i < expected.length; i++) {
    final y = i ~/ _width;
    final sourceY =
        (_strips - 1 - y ~/ stripHeight) * stripHeight + y % stripHeight;
    if (restored.getPixelAtIndex(i).value !=
        expected[sourceY * _width + i % _width]) {
      fail('Transformed pixel mismatch at $i');
    }
  }

  // Separately measure the unmodified production path (including its isolate).
  final fresh = Stopwatch()..start();
  final actual = await processing.modifyImageWithScript(source, script);
  await _displayDecode(actual);
  fresh.stop();
  expect(actual, orderedEquals(encoded.$1));
  return {
    'decodeToStraightRgbaMs': _ms(decode),
    'scriptWorkerAndPngMs': _ms(worker),
    'pngEncodeMs': encoded.$2,
    'scriptAndWorkerOverheadMs': _ms(worker) - encoded.$2,
    'cachedPngDisplayDecodeMs': cachedDecode,
    'productionFreshToDisplayMs': _ms(fresh),
    'pngBytes': actual.length,
    'rssAfterBytes': ProcessInfo.currentRss,
    'processPeakRssBytes': ProcessInfo.maxRss,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'report image pipeline phases using production codecs and script',
    () async {
      if (_width <= 0 || _height <= 0 || _height % _strips != 0 || _runs < 1) {
        throw ArgumentError(
          'Positive dimensions/runs and height divisible by 16 required',
        );
      }
      if (Platform.isWindows) {
        final native = Directory(
          'build/windows/x64/runner/Release',
        ).absolute.path;
        for (final name in [
          'flutter_windows.dll',
          'flutter_qjs_plugin.dll',
          'venera_native.dll',
        ]) {
          DynamicLibrary.open('$native/$name');
        }
      }
      final initialization = await rootBundle.loadString('assets/init.js');
      for (final kind in ['monochrome', 'color']) {
        final pixels = _pixels(kind);
        final source = processing.Image(pixels, _width, _height).encodePng();
        for (var run = 0; run <= _runs; run++) {
          final result = await _measure(source, initialization, pixels);
          // Run zero is warm-up. RSS includes the host and validation allocations.
          if (run == 0) continue;
          // ignore: avoid_print
          print(
            jsonEncode({
              'probe': 'image_pipeline',
              'platform': Platform.operatingSystem,
              'dart': Platform.version,
              'mode': 'flutter-test-host',
              'kind': kind,
              'width': _width,
              'height': _height,
              'run': run,
              ...result,
            }),
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
