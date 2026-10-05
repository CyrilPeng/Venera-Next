import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nativeAvailable = true;
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
  } catch (_) {
    nativeAvailable = false;
  }
  group(
    'native Cookie bridge',
    () {
      late Directory directory;
      late JsEngine engine;
      late SingleInstanceCookieJar? previous;
      late bool initialized;
      late bool muted;
      setUp(() async {
        previous = SingleInstanceCookieJar.instance;
        initialized = App.isInitialized;
        muted = Log.isMuted;
        SingleInstanceCookieJar.instance = null;
        App.isInitialized = false;
        Log.isMuted = true;
        directory = Directory.systemTemp.createTempSync('js-cookie-');
        SingleInstanceCookieJar('${directory.path}/cookie.db');
        engine = JsEngine.create(
          createHttpClient: Dio.new,
          loadInitScript: () => File('assets/init.js').readAsBytes(),
        );
        await engine.init();
      });
      tearDown(() {
        engine.dispose();
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = previous;
        App.isInitialized = initialized;
        Log.isMuted = muted;
        directory.deleteSync(recursive: true);
      });

      test(
        'real JS cookies remain synchronous and ordered for existing sources',
        () {
          expect(
            engine.runCode('''
      (() => {
        const set = Network.setCookies('https://example.test/', [{name:'session', value:'saved'}]);
        const cookies = Network.getCookies('https://example.test/');
        const deleted = Network.deleteCookies('https://example.test/');
        return [set === undefined, Array.isArray(cookies), cookies[0].value,
          deleted === undefined, Network.getCookies('https://example.test/').length];
      })()
    '''),
            [true, true, 'saved', true, 0],
          );
        },
      );

      test(
        'JS receives synchronous busy errors with zero cookie writes',
        () async {
          final release = Completer<void>();
          final replacement = AppDataOperations.instance.run(
            () => release.future,
          );
          try {
            final cookieJar = SingleInstanceCookieJar.instance!;
            expect(cookieJar.dispose, throwsA(isA<AppDataBusyException>()));
            expect(SingleInstanceCookieJar.instance, same(cookieJar));
            expect(
              engine.runCode('''
        (() => {
          const errors = [];
          for (const action of [
            () => Network.setCookies('https://example.test/', [{name:'session', value:'wrong'}]),
            () => Network.getCookies('https://example.test/'),
            () => Network.deleteCookies('https://example.test/')]) {
            try { action(); errors.push('no error'); }
            catch (error) { errors.push(String(error)); }
          }
          return errors;
        })()
      '''),
              everyElement(contains('Application data is busy')),
            );
          } finally {
            release.complete();
            await replacement;
          }
          expect(
            SingleInstanceCookieJar.instance!.loadForRequest(
              Uri.parse('https://example.test/'),
            ),
            isEmpty,
          );
        },
      );

      test(
        'JS cannot silently save or read against a missing cookie database',
        () {
          SingleInstanceCookieJar.instance!.dispose();
          expect(
            engine.runCode('''
      (() => {
        try { Network.setCookies('https://example.test/', []); return 'no error'; }
        catch (error) { return String(error); }
      })()
    '''),
            contains('Cookie database is not initialized'),
          );
        },
      );

      test(
        'asynchronous owner capture waits for replacement and rejects missing stores',
        () async {
          final old = SingleInstanceCookieJar.instance!;
          final release = Completer<void>();
          final replacement = AppDataOperations.instance.run(() async {
            old.dispose();
            await release.future;
            SingleInstanceCookieJar(old.path);
          });
          final owner = SingleInstanceCookieJar.captureInstance();
          final initializedOwner = SingleInstanceCookieJar.createInstance(
            directory: directory.path,
          );
          release.complete();
          await replacement;
          expect(await owner, same(SingleInstanceCookieJar.instance));
          expect(await owner, isNot(same(old)));
          expect(await initializedOwner, same(await owner));
          SingleInstanceCookieJar.instance!.dispose();
          await expectLater(
            SingleInstanceCookieJar.captureInstance(),
            throwsStateError,
          );
        },
      );
    },
    skip: nativeAvailable ? false : 'QuickJS native library is unavailable',
  );
}
