// Host diagnostics only, not Android frame pacing or power measurements.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/image_provider/reader_image_processing.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:yaml/yaml.dart';

const _width = int.fromEnvironment(
  'READER_PROCESSING_WIDTH',
  defaultValue: 1500,
);
const _height = int.fromEnvironment(
  'READER_PROCESSING_HEIGHT',
  defaultValue: 2400,
);
const _runs = int.fromEnvironment('READER_PROCESSING_RUNS', defaultValue: 9);
const _burst = int.fromEnvironment('READER_PROCESSING_BURST', defaultValue: 8);
const _output = String.fromEnvironment(
  'READER_PROCESSING_OUTPUT',
  defaultValue: 'build/reader-processing-probe/report.json',
);

enum _Mode {
  disabled,
  synchronousIdentity,
  defaultScript;

  String get script => switch (this) {
    disabled => throw StateError('Disabled processing has no script'),
    synchronousIdentity => 'function processImage(image) { return image; }',
    defaultScript => defaultCustomImageProcessing,
  };
}

class _Sample {
  _Sample(this.bytes, this.width, this.height, this.timings);

  final Uint8List bytes;
  final int width, height;
  final Map<String, int> timings;
}

Map<String, int> _summary(Iterable<int> samples) {
  final values = samples.toList()..sort();
  int percentile(double fraction) =>
      values[math.max(0, (values.length * fraction).ceil() - 1)];
  return {
    'count': values.length,
    'p50Us': percentile(0.5),
    'p95Us': percentile(0.95),
    'maxUs': values.last,
  };
}

Future<_Sample> _measure(Uint8List source, _Mode mode, int page) async {
  final cancel = Completer<void>();
  ui.Codec? codec;
  ui.Image? decoded;
  try {
    final total = Stopwatch()..start();
    final processing = Stopwatch()..start();
    final bytes = mode == _Mode.disabled
        ? source
        : await processReaderImageBytes(
            source,
            script: mode.script,
            comicId: 'synthetic',
            episodeId: 'synthetic',
            page: page,
            sourceKey: null,
            checkStop: () {},
            cancelSignal: cancel.future,
          );
    processing.stop();
    final codecTime = Stopwatch()..start();
    codec = await ui.instantiateImageCodec(bytes);
    codecTime.stop();
    final firstFrame = Stopwatch()..start();
    decoded = (await codec.getNextFrame()).image;
    firstFrame.stop();
    total.stop();
    return _Sample(bytes, decoded.width, decoded.height, {
      'processingWaitUs': processing.elapsedMicroseconds,
      'codecInitWaitUs': codecTime.elapsedMicroseconds,
      'firstDecodeWaitUs': firstFrame.elapsedMicroseconds,
      'encodedToFirstFrameWaitUs': total.elapsedMicroseconds,
    });
  } finally {
    decoded?.dispose();
    codec?.dispose();
    cancel.complete();
  }
}

void _loadNativeLibrary() {
  if (Platform.isWindows) {
    const configured = String.fromEnvironment('READER_PROCESSING_NATIVE_DIR');
    final native = Directory(
      configured.isEmpty ? 'build/windows/x64/runner/Release' : configured,
    ).absolute.path;
    DynamicLibrary.open(path.join(native, 'flutter_windows.dll'));
    DynamicLibrary.open(path.join(native, 'flutter_qjs_plugin.dll'));
  } else {
    DynamicLibrary.open(
      Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'compare disabled and identity processing with real QuickJS and codecs',
    () async {
      if (_width <= 0 ||
          _height <= 0 ||
          _width * _height > 16000000 ||
          _runs < 1 ||
          _runs > 100 ||
          _burst < 1 ||
          _burst > 32) {
        throw ArgumentError('Use 1-100 runs, 1-32 images, and <=16M pixels');
      }
      // Missing native dependencies must fail, never become a skipped probe.
      _loadNativeLibrary();
      final root = Directory('build/reader-processing-probe')
        ..createSync(recursive: true);
      final runtime = root.createTempSync('runtime-');
      final manifest = loadYaml(await File('pubspec.yaml').readAsString());
      final lock = loadYaml(await File('pubspec.lock').readAsString());
      App.dataPath = runtime.path;
      App.cachePath = runtime.path;
      App.version = manifest['version'] as String;
      final engine = JsEngine();
      try {
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await engine.init();
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
        final groups = <Map<String, Object>>[];
        final referenceWalks = <Map<String, Object>>[];
        for (final fixture in fixtures.entries) {
          final original = Uint8List.fromList(fixture.value);
          for (final count in {1, _burst}) {
            final samples = {
              for (final mode in _Mode.values) mode: <Map<String, int>>[],
            };
            final batchTimes = {for (final mode in _Mode.values) mode: <int>[]};
            // Round zero warms every case; rotate later order to reduce bias.
            for (var run = 0; run <= _runs; run++) {
              for (var index = 0; index < _Mode.values.length; index++) {
                final mode = _Mode.values[(run + index) % _Mode.values.length];
                final batch = Stopwatch()..start();
                final results = await Future.wait([
                  for (var page = 0; page < count; page++)
                    _measure(fixture.value, mode, page),
                ]);
                batch.stop();
                // Validation must not inflate another in-flight sample's wait.
                for (final result in results) {
                  expect(listEquals(result.bytes, original), isTrue);
                  expect((result.width, result.height), (_width, _height));
                  if (run != 0) samples[mode]!.add(result.timings);
                }
                expect(listEquals(fixture.value, original), isTrue);
                await Future<void>.delayed(Duration.zero);
                // ignore: invalid_use_of_visible_for_testing_member
                expect(engine.debugOwnedReferenceCount, 0);
                if (run != 0) {
                  batchTimes[mode]!.add(batch.elapsedMicroseconds);
                }
              }
            }
            for (final mode in _Mode.values) {
              final values = samples[mode]!;
              final summary = {
                for (final stage in values.first.keys)
                  stage: _summary(values.map((sample) => sample[stage]!)),
              };
              final group = <String, Object>{
                'format': fixture.key,
                'encodedBytes': fixture.value.length,
                'processing': mode.name,
                'imagesPerBatch': count,
                'batches': _runs,
                'summary': summary,
                'batchWallWait': _summary(batchTimes[mode]!),
                'samples': values,
                'batchWallWaitUs': batchTimes[mode]!,
              };
              groups.add(group);
              // ignore: avoid_print
              print(
                jsonEncode(
                  {...group}
                    ..remove('samples')
                    ..remove('batchWallWaitUs'),
                ),
              );
            }
          }
          final walks = <int>[];
          for (var run = 0; run <= _runs; run++) {
            final clock = Stopwatch()..start();
            JSRef.dupRecursive(fixture.value);
            JSRef.freeRecursive(fixture.value);
            clock.stop();
            if (run != 0) walks.add(clock.elapsedMicroseconds);
          }
          referenceWalks.add({
            'format': fixture.key,
            'encodedBytes': fixture.value.length,
            'pairedDupAndFreeWalk': _summary(walks),
            'samplesUs': walks,
          });
        }
        final report = {
          'schema': 1,
          'probe': 'reader_processing',
          'platform': Platform.operatingSystem,
          'dart': Platform.version,
          'mode': 'flutter-test-host',
          'appVersion': App.version,
          'configuration': const String.fromEnvironment(
            'READER_PROCESSING_CONFIGURATION',
            defaultValue: 'locked-baseline',
          ),
          'sourceRevision': const String.fromEnvironment(
            'READER_PROCESSING_REVISION',
            defaultValue: 'unspecified',
          ),
          'quickJsRevision':
              lock['packages']['flutter_qjs']['description']['resolved-ref'] ??
              'local experiment; see configuration',
          'quickJsSource': lock['packages']['flutter_qjs']['source'],
          'input': 'generated-encoded-memory',
          'width': _width,
          'height': _height,
          'quantiles': 'nearest-rank; descriptive only, no timing assertions',
          'limitations': [
            'Elapsed waits are not CPU time, UI blocking, Android FPS or power.',
            'No file/network I/O, reader layout, scroll scheduling or image cache.',
            'Synthetic bursts do not change production concurrency or settings.',
            'Reference walks run separately; do not add them to pipeline waits.',
          ],
          'groups': groups,
          'referenceWalks': referenceWalks,
        };
        final output = File(_output);
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      } finally {
        await engine.closeAndWait();
        final resolvedRoot = root.resolveSymbolicLinksSync();
        final resolvedRuntime = runtime.resolveSymbolicLinksSync();
        if (!path.isWithin(resolvedRoot, resolvedRuntime)) {
          throw StateError(
            'Refusing to remove a runtime outside the probe root',
          );
        }
        runtime.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
