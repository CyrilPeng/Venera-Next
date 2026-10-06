import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/data_sync.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/app_runtime/webdav_library.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/network/cookie_jar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'application final admission saves state and releases actual core stores',
    () async {
      final root = Directory.systemTemp.createTempSync('application-host-');
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
      final sync = createApplicationDataSync();
      final core = createCoreBootstrap(
        onDataChanged: sync.onDataChanged,
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/temp')..createSync()).path;
          App.version = '9.0.0';
          App.isInitialized = true;
        },
      );
      final host = ApplicationHost(
        core: core,
        sync: sync,
        sourceUpdates: SourceUpdateService(),
      );
      configureHeadlessBindings();
      await core.start();
      final engine = JsEngine();
      final sources = ComicSourceManager();
      final history = HistoryManager();
      final favorites = LocalFavoritesManager();
      final local = LocalManager();
      final library = webDavLibrary.source;
      sync.start();
      await appdata.updateSettings((draft) => draft['cacheSize'] = 321);
      final closing = host.close();
      expect(identical(closing, host.close()), isTrue);
      await closing;
      expect(AppDataOperations.instance.isClosing, isTrue);
      expect(history.isInitialized, isFalse);
      expect(() => favorites.databasePath, throwsStateError);
      expect(() => local.count, throwsStateError);
      expect(CacheManager.instance, isNull);
      expect(library.isDisposed, isTrue);
      expect(SingleInstanceCookieJar.instance, isNull);
      expect(() => engine.runCode('1'), throwsStateError);
      await expectLater(sources.init(), throwsStateError);
      await expectLater(
        appdata.updateSettings((draft) => draft['cacheSize'] = 999),
        throwsA(isA<AppDataClosedException>()),
      );
      expect(
        File('${root.path}/appdata.json').readAsStringSync(),
        contains('321'),
      );
      final ownership = SqliteDataSyncOwnership(() => root.path);
      ownership.acquire();
      ownership.release();
      await host.close();
      await root.delete(recursive: true);
    },
    skip: !Platform.isWindows,
  );
}
