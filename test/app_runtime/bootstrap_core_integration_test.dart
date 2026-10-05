import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real core closes native resources and a replaced cookie connection',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-core-');
      // The Windows engine DLL is needed by the native QJS plugin in flutter test.
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      var dataChanges = 0;
      final core = createCoreBootstrap(
        onDataChanged: () => dataChanges++,
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/temp')..createSync()).path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      addTearDown(() async {
        await core.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      configureHeadlessBindings();
      await core.start();
      final engine = JsEngine();
      final sources = ComicSourceManager();
      final history = HistoryManager();
      final favorites = LocalFavoritesManager();
      final local = LocalManager();
      final cache = CacheManager.instance!;
      final librarySource = webDavLibrary.source;
      final originalCookies = SingleInstanceCookieJar.instance!;
      expect(App.rootNavigatorKey.currentContext, isNull);
      expect(dataChanges, 0);
      expect(File('${root.path}/appdata.json').existsSync(), isTrue);
      expect(File('${root.path}/cookie.db').existsSync(), isTrue);
      expect(local.path, startsWith(root.path));
      expect(ComicSource.all(), isEmpty);
      expect(engine.runCode('1 + 1'), 2);
      expect(librarySource.isDisposed, isFalse);
      expect(history.isInitialized, isTrue);
      await appdata.saveData(false);
      await appdata.updateSettings((draft) => draft['cacheSize'] = 0);
      await cache.writeCache('limit-from-settings', [1]);
      expect(await cache.findCache('limit-from-settings'), isNull);

      // Sync import closes and reconstructs the same application's cookie jar.
      // Use a different spelling of the path to exercise normalized ownership.
      final uri = Uri.parse('https://core.example.test/path');
      originalCookies.saveFromResponse(uri, [
        Cookie('session', 'before-import'),
      ]);
      originalCookies.dispose();
      expect(() => originalCookies.loadForRequest(uri), throwsStateError);
      expect(SingleInstanceCookieJar.instance, isNull);
      final replacementCookies = SingleInstanceCookieJar(
        '${root.path}${Platform.pathSeparator}.${Platform.pathSeparator}cookie.db',
      );
      expect(replacementCookies, isNot(same(originalCookies)));
      expect(replacementCookies.path, isNot(originalCookies.path));
      expect(
        path.equals(replacementCookies.path, originalCookies.path),
        isTrue,
      );
      expect(
        replacementCookies.loadForRequestCookieHeader(uri),
        'session=before-import',
      );
      replacementCookies.saveFromResponse(uri, [
        Cookie('session', 'after-import'),
      ]);

      final closing = core.close();
      expect(core.close(), same(closing));
      await closing;
      expect(() => engine.runCode('1'), throwsStateError);
      await expectLater(sources.init(), throwsStateError);
      expect(ComicSource.all(), isEmpty);
      expect(history.isInitialized, isFalse);
      expect(history.hasPendingWrites, isFalse);
      expect(() => history.length, throwsStateError);
      expect(() => favorites.databasePath, throwsStateError);
      expect(() => local.count, throwsStateError);
      expect(CacheManager.instance, isNull);
      appdata.settings['cacheSize'] = 1;
      expect(CacheManager.instance, isNull);
      await expectLater(cache.findCache('closed'), throwsStateError);
      expect(librarySource.isDisposed, isTrue);
      expect(SingleInstanceCookieJar.instance, isNull);
      expect(() => replacementCookies.loadForRequest(uri), throwsStateError);
      await expectLater(core.start(), throwsStateError);

      final persistedCookies = CookieJarSql(originalCookies.path);
      try {
        expect(
          persistedCookies.loadForRequestCookieHeader(uri),
          'session=after-import',
        );
      } finally {
        persistedCookies.dispose();
      }
      // On Windows this also verifies that SQLite and plugin handles are gone.
      await root.delete(recursive: true);
      expect(await root.exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
