import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/app_runtime/bootstrap_core.dart';
import 'package:venera_next/app_runtime/headless_bindings.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/init.dart';
import 'package:venera_next/foundation/js_engine.dart';

import '../support/legacy_favorites_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nativeAvailable = true;
  try {
    if (Platform.isWindows) {
      final native = Directory(
        'build/windows/x64/runner/Release',
      ).absolute.path;
      DynamicLibrary.open('$native/flutter_windows.dll');
      DynamicLibrary.open('$native/flutter_qjs_plugin.dll');
    } else {
      DynamicLibrary.open(
        Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
    }
  } catch (_) {
    nativeAvailable = false;
  }

  test(
    'legacy startup opens analyzed favorites while source initialization waits for network',
    () async {
      final root = Directory.systemTemp.createTempSync('legacy-startup-init-');
      final sources = Directory('${root.path}/comic_source')..createSync();
      File('${root.path}/appdata.json').writeAsStringSync(
        jsonEncode({
          'settings': {
            'deviceId': 'legacy-device',
            'readerMode': 'galleryRightToLeft',
            'comicSourceListUrl': 'https://example.invalid/sources.json',
            'webdav': ['https://example.invalid/dav/', 'fixture', 'fixture'],
            'disableSyncFields': '',
            'followUpdatesFolder': 'sqliteXnotes',
            'quickFavorite': 'legacy',
          },
          'searchHistory': ['preserved search'],
        }),
      );
      File('${sources.path}/source.js').writeAsStringSync('''
        class StartupSource extends ComicSource {
          key = 'startup_fixture'; name = 'Startup fixture'; version = '1.0.0';
          minAppVersion = '1.0.0';
          async init() {
            await new Promise(resolve => { globalThis.finishStartupInit = resolve; });
            this.saveData('initialized', true);
          }
          comic = {loadInfo: async () => ({title: 'Fixture', cover: '', tags: {}}),
                   loadEp: async () => []};
        }
      ''');
      final history = sqlite3.open('${root.path}/history.db');
      history.execute('CREATE TABLE legacy_marker (value TEXT)');
      history.execute("INSERT INTO legacy_marker VALUES ('preserved history')");
      history.dispose();
      final favorites = sqlite3.open('${root.path}/local_favorite.db');
      late Map<String, Object?> internalBefore;
      try {
        seedAnalyzedLegacyFavorites(favorites);
        // SQLite drops obsolete statistics for rebuilt hierarchy metadata.
        internalBefore = sqliteInternalTableSnapshot(
          favorites,
          excludeStatisticsFor: {'folder_order'},
        );
      } finally {
        favorites.dispose();
      }
      configureHeadlessBindings();
      final core = createCoreBootstrap(
        onDataChanged: () {},
        environment: () async {
          App.dataPath = root.path;
          App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
          App.version = '1.18.0';
          App.isInitialized = true;
        },
      );
      final starting = core.start();
      var started = false;
      Object? startupError;
      unawaited(
        starting.then<void>(
          (_) => started = true,
          onError: (Object error, StackTrace stack) {
            startupError = error;
          },
        ),
      );
      final engine = JsEngine();
      try {
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (engine.initializationState == InitializationState.ready &&
              engine.runCode('typeof finishStartupInit === "function"') ==
                  true) {
            break;
          }
        }
        expect(
          engine.runCode('typeof finishStartupInit === "function"'),
          isTrue,
        );
        for (var i = 0; i < 200 && !started && startupError == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (startupError != null) await starting;
        expect(started, isTrue);
        expect(HistoryManager().isInitialized, isTrue);
        final manager = LocalFavoritesManager();
        expect(manager.folderNames, ['sqliteXnotes', 'legacy']);
        expect(manager.counts, {'sqliteXnotes': 1, 'legacy': 1});
        expect(manager.totalComics, 2);
        expect(
          manager.getFolderComics('legacy').single.time,
          '2001-02-03 04:05:06',
        );
        final favorites = sqlite3.open(
          manager.databasePath,
          mode: OpenMode.readOnly,
        );
        try {
          expect(sqliteInternalTableSnapshot(favorites), internalBefore);
        } finally {
          favorites.dispose();
        }
        expect(appdata.searchHistory, ['preserved search']);
        expect(appdata.settings['readerMode'], 'galleryRightToLeft');
        expect(appdata.implicitData['webdavAutoSync'], isTrue);
        final persisted = sqlite3.open(
          '${root.path}/history.db',
          mode: OpenMode.readOnly,
        );
        try {
          expect(
            persisted.select('SELECT value FROM legacy_marker').single['value'],
            'preserved history',
          );
        } finally {
          persisted.dispose();
        }
      } finally {
        if (engine.initializationState == InitializationState.ready &&
            engine.runCode('typeof finishStartupInit === "function"') == true) {
          engine.runCode('void finishStartupInit()');
        }
        try {
          await starting;
        } finally {
          await core.close();
          await root.delete(recursive: true);
        }
      }
    },
    skip: !nativeAvailable ? 'QuickJS native library unavailable' : false,
  );
}
