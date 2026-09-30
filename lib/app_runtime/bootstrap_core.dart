import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/cookie_jar.dart';

import 'core_bootstrap.dart';

/// Core startup never registers window callbacks or automatic sync timers.
Future<void> bootstrapCore() => _core.start();

final _core = createCoreBootstrap();

/// Override platform path setup for embedded hosts and isolated integration tests.
CoreBootstrap createCoreBootstrap({Future<void> Function()? environment}) =>
    CoreBootstrap(
      environment: environment ?? App.init,
      settings: appdata.init,
      infrastructure: () async {
        await SingleInstanceCookieJar.createInstance(directory: App.dataPath);
        await Future.wait([
          Rhttp.init(),
          _optional('SAF worker', () => SAFTaskWorker().init()),
          _optional('App translations', AppTranslation.init),
          _optional('Tag translations', TagsTranslation.readData),
          OpenCC.init(),
        ]);
      },
      sources: () async {
        configureComicTypeSourceKeyResolver();
        configureComicSourceDataSavedHandler(
          () async => DataSync().onDataChanged(),
        );
        configureRuntimeComicSourcesProvider(
          () => WebDavLibraryConfig.fromSettings().isValid
              ? [WebDavLibrarySource.create()]
              : const [],
        );
        await JsEngine().init();
        await ComicSourceManager().init();
      },
      stores: () => Future.wait([
        HistoryManager().init(),
        LocalFavoritesManager().init(),
        LocalManager().init(),
      ]).then((_) {}),
      finish: () async {
        _checkOldConfigs();
        CacheManager().setLimitSize(appdata.settings['cacheSize']);
      },
    );

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

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }
}
