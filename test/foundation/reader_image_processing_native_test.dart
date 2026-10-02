import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:venera_next/foundation/image_provider/reader_image_processing.dart';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool nativeAvailable;
  try {
    if (Platform.isWindows) {
      final build = Directory('build/windows/x64/runner/Release').absolute.path;
      if (File('$build/flutter_windows.dll').existsSync()) {
        DynamicLibrary.open('$build/flutter_windows.dll');
        DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
      }
    }
    DynamicLibrary.open(
      Platform.isWindows
          ? 'flutter_qjs_plugin.dll'
          : Platform.isLinux
          ? 'libflutter_qjs_plugin.so'
          : 'flutter_qjs.framework/flutter_qjs',
    );
    nativeAvailable = true;
  } catch (_) {
    nativeAvailable = false;
  }

  group(
    'native image processing',
    () {
      late Directory directory;
      late Map<String, dynamic> settings;
      final manager = ComicSourceManager();
      setUp(() async {
        directory = Directory.systemTemp.createTempSync(
          'venera-source-transaction-',
        );
        Directory('${directory.path}/comic_source').createSync();
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        App.version = '9.0.0';
        settings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
        Log.isMuted = true;
        JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
        await JsEngine().init();
      });
      tearDown(() async {
        for (final key in ['transaction_a', 'transaction_b']) {
          manager.remove(key);
        }
        await appdata.saveData(false);
        JsEngine().dispose();
        settings.forEach((key, value) => appdata.settings[key] = value);
        Log.isMuted = false;
        directory.deleteSync(recursive: true);
      });

      Future<Uint8List> process(
        String script, {
        Future<void>? cancelSignal,
        void Function()? checkStop,
      }) => processReaderImageBytes(
        Uint8List.fromList([1, 2]),
        script: script,
        comicId: 'comic',
        episodeId: 'episode',
        page: 3,
        sourceKey: 'source',
        checkStop: checkStop ?? () {},
        cancelSignal: cancelSignal ?? Completer<void>().future,
      );
      for (final expression in [
        'new Uint8Array([3, 4]).buffer',
        'Promise.resolve(new Uint8Array([3, 4]).buffer)',
        '({image:new Uint8Array([3, 4]).buffer, onCancel:()=>{throw new Error("unexpected cancel");}})',
        '({image:Promise.resolve(new Uint8Array([3, 4]).buffer), onCancel:()=>{throw new Error("unexpected cancel");}})',
      ]) {
        test('processImage return protocol: $expression', () async {
          final bytes = await process(
            '''function processImage(bytes, cid, eid, page, source) {
            if (cid !== "comic" || eid !== "episode" || page !== 3 || source !== "source" || new Uint8Array(bytes)[0] !== 1) throw new Error("arguments");
            return $expression;
          }''',
          );
          expect(bytes, [3, 4]);
        });
      }
      test(
        'processing exceptions release callbacks and preserve the error',
        () async {
          await expectLater(
            process(
              'function processImage() { throw new Error("processing failed"); }',
            ),
            throwsA(
              predicate((e) => e.toString().contains('processing failed')),
            ),
          );
          await expectLater(
            process(
              'function processImage() { return Promise.reject(new Error("async failed")); }',
            ),
            throwsA(predicate((e) => e.toString().contains('async failed'))),
          );
        },
      );
      test('cancellation calls native hook once and releases it', () async {
        var stopped = false;
        final signal = Completer<void>();
        final result = process(
          r'''
          function processImage() {
            globalThis.cancelCount = 0;
            let finish;
            const image = new Promise(resolve => finish = resolve);
            return {image, onCancel: () => { globalThis.cancelCount++; finish(new Uint8Array([9]).buffer); }};
          }
        ''',
          cancelSignal: signal.future,
          checkStop: () {
            if (stopped) throw StateError('stopped');
          },
        );
        stopped = true;
        signal.complete();
        await expectLater(result, throwsStateError);
        await pumpEventQueue();
        expect(JsEngine().runCode('globalThis.cancelCount'), 1);
      });
      test(
        'unsupported result retains original bytes and frees ignored callbacks',
        () async {
          expect(
            await process(
              'function processImage() { return {image:42, unused:()=>1}; }',
            ),
            [1, 2],
          );
          expect(
            await process(
              'function processImage() { return Promise.resolve(null); }',
            ),
            isEmpty,
          );
        },
      );
    },
    skip: nativeAvailable
        ? false
        : 'QuickJS native library unavailable; run with platform build DLLs on PATH.',
  );
}
