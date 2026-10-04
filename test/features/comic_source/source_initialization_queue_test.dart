import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/js_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reload waits for initial loading before replacing JS registry',
    () async {
      final root = Directory.systemTemp.createTempSync('source-init-queue-');
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      App.dataPath = root.path;
      App.cachePath = root.path;
      App.version = '9.0.0';
      JsEngine.cacheJsInit(await File('assets/init.js').readAsBytes());
      final engine = JsEngine();
      await engine.init();
      final manager = ComicSourceManager();
      final seenRegistry = <bool>[];
      engine.runCode('ComicSource.sources.sentinel = {};');
      configureRuntimeComicSourcesProvider(() {
        seenRegistry.add(
          engine.runCode('ComicSource.sources.sentinel !== undefined') as bool,
        );
        return [];
      });
      try {
        // Source migration waits for explicitly started settings initialization.
        final starting = manager.init();
        expect(manager.init(), same(starting));
        var reloaded = false;
        final reload = manager.reload().then((_) => reloaded = true);
        await pumpEventQueue();
        expect(seenRegistry, isEmpty);
        expect(reloaded, isFalse);
        expect(
          engine.runCode('ComicSource.sources.sentinel !== undefined'),
          isTrue,
        );
        await appdata.init();
        await starting;
        await reload;
        expect(seenRegistry, [true, false]);
        expect(reloaded, isTrue);
      } finally {
        configureRuntimeComicSourcesProvider(null);
        await appdata.saveData(false);
        engine.dispose();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );
}
