import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'later store failure closes source manager and JS runtime',
    () async {
      final root = Directory.systemTemp.createTempSync('core-source-rollback-');
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      await File(
        '${root.path}/local.db',
      ).writeAsString('invalid sqlite database');
      final engine = JsEngine();
      final sources = ComicSourceManager();
      configureHeadlessBindings();
      final core = createCoreBootstrap(
        onDataChanged: () {},
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/temp')..createSync()).path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      try {
        await expectLater(core.start(), throwsA(anything));
        expect(() => engine.runCode('1'), throwsStateError);
        await expectLater(sources.init(), throwsStateError);
        expect(ComicSource.all(), isEmpty);
        expect(SingleInstanceCookieJar.instance, isNull);
        final replacement = ComicSourceManager();
        expect(replacement, isNot(same(sources)));
        await replacement.closeAndWait();
      } finally {
        await sources.closeAndWait();
        engine.dispose();
        SingleInstanceCookieJar.instance?.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
