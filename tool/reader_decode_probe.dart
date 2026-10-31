// Host diagnostics only: this does not measure Android frame pacing or power.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/image_provider/reader_image.dart';

const _width = int.fromEnvironment('READER_PROBE_WIDTH', defaultValue: 1500);
const _height = int.fromEnvironment('READER_PROBE_HEIGHT', defaultValue: 2400);
const _runs = int.fromEnvironment('READER_PROBE_RUNS', defaultValue: 5);

double _ms(Stopwatch clock) => clock.elapsedMicroseconds / 1000;

Future<Map<String, Object>> _measure(
  ReaderImageProvider provider,
  Uint8List expected, {
  required bool readFile,
}) async {
  final total = Stopwatch()..start();
  final read = Stopwatch()..start();
  Uint8List bytes;
  if (readFile) {
    final chunks = StreamController<ImageChunkEvent>.broadcast();
    try {
      bytes = await provider.load(chunks, () {});
    } finally {
      await chunks.close();
    }
  } else {
    bytes = expected;
  }
  read.stop();
  final bufferTime = Stopwatch()..start();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  bufferTime.stop();
  final codecTime = Stopwatch()..start();
  final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
    buffer,
  );
  codecTime.stop();
  ui.FrameInfo? frame;
  try {
    final frameTime = Stopwatch()..start();
    frame = await codec.getNextFrame();
    frameTime.stop();
    total.stop();
    expect((frame.image.width, frame.image.height), (_width, _height));
    expect(bytes, orderedEquals(expected));
    return {
      'readMs': _ms(read),
      'bufferMs': _ms(bufferTime),
      'codecMs': _ms(codecTime),
      'firstFrameMs': _ms(frameTime),
      'totalMs': _ms(total),
      'encodedBytes': bytes.length,
      'decodedRgbaBytes': frame.image.width * frame.image.height * 4,
    };
  } finally {
    frame?.image.dispose();
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('report synthetic local-reader image decode phases', () async {
    if (_width <= 0 || _height <= 0 || _runs <= 0) {
      throw ArgumentError('Positive dimensions and run count required');
    }
    final root = Directory('build/reader-decode-probe')..createSync();
    final directory = root.createTempSync('run-');
    final previousProcessing = appdata.settings['enableCustomImageProcessing'];
    appdata.settings['enableCustomImageProcessing'] = false;
    try {
      final pixels = image.Image(width: _width, height: _height);
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
      final fixtures = {
        'png': image.encodePng(pixels),
        'jpeg': image.encodeJpg(pixels, quality: 90),
      };
      for (final entry in fixtures.entries) {
        final file = File('${directory.path}/synthetic.${entry.key}').absolute;
        await file.writeAsBytes(entry.value, flush: true);
        final provider = ReaderImageProvider(
          'file://${file.path}',
          null,
          'synthetic',
          'chapter',
          1,
        );
        for (final readFile in [true, false]) {
          for (var run = 0; run <= _runs; run++) {
            final result = await _measure(
              provider,
              entry.value,
              readFile: readFile,
            );
            if (run == 0) continue;
            // ignore: avoid_print
            print(
              jsonEncode({
                'probe': 'reader_decode',
                'platform': Platform.operatingSystem,
                'dart': Platform.version,
                'mode': 'flutter-test-host',
                'format': entry.key,
                'input': readFile ? 'local-file' : 'encoded-memory',
                'width': _width,
                'height': _height,
                'run': run,
                ...result,
              }),
            );
          }
        }
      }
    } finally {
      appdata.settings['enableCustomImageProcessing'] = previousProcessing;
    }
  });
}
