import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real core starts with isolated data and no widget tree',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-core-');
      // The Windows engine DLL is needed by the native QJS plugin in flutter test.
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      final core = createCoreBootstrap(
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/temp')..createSync()).path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      configureHeadlessBindings();
      await core.start();
      expect(App.rootNavigatorKey.currentContext, isNull);
      expect(DataSync.instance, isNull);
      expect(File('${root.path}/appdata.json').existsSync(), isTrue);
      expect(File('${root.path}/cookie.db').existsSync(), isTrue);
      expect(LocalManager().path, startsWith(root.path));
      expect(ComicSource.all(), isEmpty);
      expect(JsEngine().runCode('1 + 1'), 2);
      await appdata.saveData(false);
      await HistoryManager().waitForAsyncWrites();

      LocalManager.resetForTesting();
      HistoryManager().close();
      LocalFavoritesManager().close();
      await CacheManager().dispose();
      CacheManager.instance = null;
      SingleInstanceCookieJar.instance?.dispose();
      SingleInstanceCookieJar.instance = null;
      JsEngine().dispose();
      await root.delete(recursive: true);
    },
    skip: !Platform.isWindows,
  );
}
