import 'dart:async';

import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as path;
import 'package:rhttp/rhttp.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/app_data_import_journal.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/js_pool.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/cookie_jar.dart';

import 'package:venera_next/features/sync/legacy_auto_sync_migration.dart';

import 'core_bootstrap.dart';
import 'core_infrastructure.dart';
import 'webdav_library.dart';

/// Core startup never registers window callbacks or automatic sync timers.
/// The caller owns this bootstrap instance and its data-change callback.
CoreBootstrap createCoreBootstrap({
  Future<void> Function()? environment,
  required void Function() onDataChanged,
}) {
  final cleanup = <CoreStartupCleanup>[];
  return CoreBootstrap(
    failureCleanup: cleanup,
    environment: environment ?? App.init,
    settings: () async {
      // Import recovery precedes settings fallback and every database opener.
      // No live application resource may observe a partly replaced snapshot.
      final imports = AppDataImportJournal.open(App.dataPath);
      try {
        await imports.recoverPending();
      } finally {
        imports.close();
      }
      await appdata.init();
    },
    infrastructure: () async {
      final previousCookies = SingleInstanceCookieJar.instance;
      await initializeCoreInfrastructure(
        directory: App.dataPath,
        services: [
          Rhttp.init,
          () => _optional('SAF worker', () => SAFTaskWorker().init()),
          () => _optional('App translations', AppTranslation.init),
          () => _optional('Tag translations', TagsTranslation.readData),
          OpenCC.init,
        ],
      );
      final cookies = SingleInstanceCookieJar.instance;
      if (cookies != null && !identical(previousCookies, cookies)) {
        cleanup.add((
          name: 'cookies',
          close: () {
            cookies.dispose();
            // Data import replaces this application's connection. The core
            // owns its replacement too, but never a different database.
            final replacement = SingleInstanceCookieJar.instance;
            if (replacement != null &&
                path.equals(replacement.path, cookies.path)) {
              replacement.dispose();
            }
          },
        ));
      }
    },
    sources: () async {
      cleanup.add((
        name: 'source bindings',
        close: () {
          configureComicSourceDataSavedHandler(null);
          configureRuntimeComicSourcesProvider(null);
        },
      ));
      configureComicTypeSourceKeyResolver();
      configureComicSourceDataSavedHandler(() async => onDataChanged());
      final library = webDavLibrary;
      cleanup.add((name: 'WebDAV library', close: library.source.closeAndWait));
      configureRuntimeComicSourcesProvider(
        () => library.settings.read().connection.isValid
            ? [library.source.create()]
            : const [],
      );
      final pool = JSPool();
      final engine = JsEngine();
      cleanup.add((name: 'JS compute pool', close: pool.close));
      cleanup.add((name: 'JS engine', close: engine.dispose));
      await engine.init();
      final sources = ComicSourceManager();
      cleanup.add((name: 'comic sources', close: sources.closeAndWait));
      await sources.init();
    },
    stores: () async {
      final history = HistoryManager();
      final favorites = LocalFavoritesManager();
      final local = LocalManager();
      final stores = <CoreStoreStartup>[
        (
          name: 'history',
          initialize: history.init,
          close: () async {
            try {
              if (history.hasPendingWrites) await history.waitForAsyncWrites();
            } finally {
              history.close();
            }
          },
        ),
        (
          name: 'favorites',
          initialize: favorites.init,
          close: favorites.closeAndWait,
        ),
        (name: 'local', initialize: local.init, close: local.dispose),
      ];
      await initializeCoreStores(stores);
      // The group handles its own failed attempt; retain only successful stores
      // for a failure in a later startup phase.
      cleanup.addAll(
        stores.map((store) => (name: store.name, close: store.close)),
      );
    },
    finish: () async {
      await _checkOldConfigs();
      final cache = CacheManager();
      cleanup.add((name: 'cache', close: cache.dispose));
      cache.setLimitSize(appdata.settings['cacheSize']);
      // The cache owns and drains this scan; UI startup need not await it.
      unawaited(cache.start());
    },
  );
}

Future<void> _optional(
  String service,
  Future<void> Function() initialize,
) async {
  try {
    await initialize();
  } catch (error, stack) {
    Log.error('init', '$service unavailable: $error', stack);
  }
}

Future<void> _checkOldConfigs() async {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  await migrateLegacyAutoSync(
    implicitData: appdata.implicitData,
    webdav: appdata.settings['webdav'],
    persist: appdata.writeImplicitData,
  );
}
