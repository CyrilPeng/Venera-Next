import 'dart:async';

import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/network/cookie_jar.dart';

import 'core_bootstrap.dart';
import 'webdav_library.dart';

/// Core startup never registers window callbacks or automatic sync timers.
/// The caller owns this bootstrap instance and its data-change callback.
CoreBootstrap createCoreBootstrap({
  Future<void> Function()? environment,
  required void Function() onDataChanged,
}) => CoreBootstrap(
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
    configureComicSourceDataSavedHandler(() async => onDataChanged());
    configureRuntimeComicSourcesProvider(
      () => webDavLibrary.settings.read().connection.isValid
          ? [webDavLibrary.source.create()]
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
    final cache = CacheManager();
    cache.setLimitSize(appdata.settings['cacheSize']);
    // The cache owns and drains this scan; UI startup need not await it.
    unawaited(cache.start());
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
