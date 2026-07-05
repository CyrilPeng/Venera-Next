import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/handle_text_share.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  configureComicTypeSourceKeyResolver();
  configureComicWidgets(
    comicPageBuilder:
        ({
          required String id,
          required String sourceKey,
          String? cover,
          String? title,
          int? heroID,
        }) => ComicPage(
          id: id,
          sourceKey: sourceKey,
          cover: cover,
          title: title,
          heroID: heroID,
        ),
    addFavorite: addFavorite,
  );
  try {
    var futures = [
      Rhttp.init(),
      App.initComponents([
        HistoryManager().init,
        LocalFavoritesManager().init,
        LocalManager().init,
      ]),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  DataSync();
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  _checkOldConfigs();
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/CyrilPeng/venera-next/issues
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
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

  if (appdata.settings['comicSourceListUrl'].toString().contains(
    "git.nyne.dev",
  )) {
    // migrate to jsdelivr cdn
    appdata.settings['comicSourceListUrl'] =
        "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
    appdata.saveData();
  }
}

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  FollowUpdatesService.initChecker();
}

void reloadComicSourcesForDebug() {
  ComicSourceManager().reload();
}
