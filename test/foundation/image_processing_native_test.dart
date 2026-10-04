import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/image_processing.dart' as processing;

class _TrackedEngine extends FlutterQjs {
  var closes = 0;
  var dispatchFinished = false;
  @override
  Future<void> dispatch() async {
    await super.dispatch();
    dispatchFinished = true;
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String initialization;
  setUpAll(() async {
    if (Platform.isWindows) {
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      DynamicLibrary.open('$native/lodepng_flutter.dll');
    }
    initialization = await File('assets/init.js').readAsString();
  });

  processing.Image input() =>
      processing.Image(Uint32List.fromList([0xff0000ff, 0xffff0000]), 2, 1);

  test(
    'native script transforms pixels and closes runtime and dispatch per task',
    () async {
      for (var attempt = 0; attempt < 3; attempt++) {
        final engine = _TrackedEngine();
        final bytes = await processing.runImageScript(
          input(),
          'function modifyImage(image) { return image.copyAndRotate90(); }',
          initializationScript: initialization,
          createEngine: () => engine,
        );
        expect(engine.closes, 1);
        expect(engine.dispatchFinished, isTrue);
        final output = await processing.Image.decodeImage(bytes);
        expect(output.width, 1);
        expect(output.height, 2);
        expect(
          output.getPixelAtIndex(0).value,
          input().getPixelAtIndex(0).value,
        );
        expect(
          output.getPixelAtIndex(1).value,
          input().getPixelAtIndex(1).value,
        );
      }
    },
    skip: !Platform.isWindows,
  );

  for (final failure in [
    'startup',
    'script',
    'bridge',
    'result-reference',
    'thrown-reference',
    'async-result',
  ]) {
    test(
      'native $failure failure releases runtime before another task',
      () async {
        final engine = _TrackedEngine();
        final script = switch (failure) {
          'script' =>
            'function modifyImage(image) { throw new Error("script failed"); }',
          'bridge' =>
            'function modifyImage(image) { return image.copyRange(-1, 0, 1, 1); }',
          'result-reference' =>
            'function modifyImage(image) { return {key: () => 1}; }',
          'thrown-reference' =>
            'function modifyImage(image) { throw {message: "script failed", callback: () => 1}; }',
          'async-result' =>
            'async function modifyImage(image) { return image; }',
          _ => 'function modifyImage(image) { return image; }',
        };
        await expectLater(
          processing.runImageScript(
            input(),
            script,
            initializationScript: failure == 'startup'
                ? 'throw new Error("startup failed");'
                : initialization,
            createEngine: () => engine,
          ),
          throwsA(anything),
        );
        expect(engine.closes, 1);
        expect(engine.dispatchFinished, isTrue);
        final replacement = _TrackedEngine();
        final bytes = await processing.runImageScript(
          input(),
          'function modifyImage(image) { return image; }',
          initializationScript: initialization,
          createEngine: () => replacement,
        );
        expect((await processing.Image.decodeImage(bytes)).width, 2);
        expect(replacement.closes, 1);
        expect(replacement.dispatchFinished, isTrue);
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'production isolate pipeline remains usable after script failure',
    () async {
      final bytes = Uint8List.fromList(input().encodePng());
      for (final failure in [
        'new Error("isolated failure")',
        '{message: "isolated failure", callback: () => 1}',
      ]) {
        await expectLater(
          processing.modifyImageWithScript(
            bytes,
            'function modifyImage(image) { throw $failure; }',
          ),
          throwsA(
            predicate((error) => error.toString().contains('isolated failure')),
          ),
        );
      }
      final result = await processing.modifyImageWithScript(
        bytes,
        'function modifyImage(image) { return image.copyAndRotate90(); }',
      );
      final output = await processing.Image.decodeImage(result);
      expect(output.width, 1);
      expect(output.height, 2);
    },
    skip: !Platform.isWindows,
  );
}
