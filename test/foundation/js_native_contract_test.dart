import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

bool _nativeAvailable() {
  try {
    if (Platform.isWindows) {
      final directory = Directory(
        Platform.environment['VENERA_NATIVE_TEST_DIRECTORY'] ??
            'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$directory/flutter_windows.dll');
      DynamicLibrary.open('$directory/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
    return true;
  } catch (_) {
    return false;
  }
}

FlutterQjs _openEngine() => FlutterQjs()..dispatch();

void _closeEngine(FlutterQjs engine) {
  engine.port.close();
  engine.close();
}

void main() {
  group(
    'pinned native wrapper contract',
    () {
      test('numbers preserve integers, NaN and infinities', () {
        final engine = _openEngine();
        try {
          for (final number in [0, -1, 2147483647, -2147483648, 4294967297]) {
            expect(engine.evaluate('$number'), number);
          }
          expect((engine.evaluate('NaN') as double).isNaN, isTrue);
          expect(engine.evaluate('Infinity'), double.infinity);
          expect(engine.evaluate('-Infinity'), double.negativeInfinity);
        } finally {
          _closeEngine(engine);
        }
      });

      test('JS Map retains entries through the Dart bridge', () {
        final engine = _openEngine();
        try {
          final result = engine.evaluate('new Map([["中文", 7], ["second", 9]])');
          try {
            expect(result, {'中文': 7, 'second': 9});
          } finally {
            JSRef.freeRecursive(result);
          }
        } finally {
          _closeEngine(engine);
        }
      });

      test(
        'Promise callbacks and copied views survive repeated teardown',
        () async {
          for (var iteration = 0; iteration < 30; iteration++) {
            final engine = _openEngine();
            JSInvokable? callback;
            try {
              expect(
                engine.evaluate('new Uint8Array([1, 2, 255]).buffer'),
                Uint8List.fromList([1, 2, 255]),
              );
              callback =
                  engine.evaluate('(fn, bytes) => Promise.resolve(fn(bytes))')
                      as JSInvokable;
              final source = Uint8List.fromList([9, 4, 5, 8]);
              final result = await callback.invoke([
                (Uint8List data) => data.map((value) => value + 1).toList(),
                Uint8List.sublistView(source, 1, 3),
              ]);
              try {
                expect(result, [5, 6]);
                expect(source, [9, 4, 5, 8]);
              } finally {
                JSRef.freeRecursive(result);
              }
              expect(
                () => engine.evaluate('throw new Error("contract failure")'),
                throwsA(isA<JSError>()),
              );
            } finally {
              callback?.free();
              _closeEngine(engine);
            }
          }
        },
      );
    },
    skip: _nativeAvailable() ? false : 'QuickJS native library unavailable',
  );
}
