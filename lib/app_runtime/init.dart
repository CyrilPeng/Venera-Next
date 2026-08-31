import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/features/sync/sync.dart';
import 'package:venera_next/features/webdav_library/webdav_library.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/js_engine.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/cookie_jar.dart';
import 'package:venera_next/features/follow_updates/follow_updates.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/handle_text_share.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/bangumi/bangumi.dart';
import 'package:venera_next/features/reader/reader.dart';

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

@visibleForTesting
Future<void> initializeBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
}) async {
  await waitForDownload();
  await createInitializer()();
}

@visibleForTesting
void startBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
}) {
  unawaited(
    initializeBangumiAfterDataSync(
      waitForDownload: waitForDownload,
      createInitializer: createInitializer,
    ).wait(),
  );
}

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  configureComicTypeSourceKeyResolver();
  configureReaderChapterCompletedHandler(
    (event) => BangumiService().onChapterCompleted(
      sourceKey: event.sourceKey,
      comicId: event.comicId,
      chapterTitle: event.chapterTitle,
    ),
  );
  configureComicSourceDataSavedHandler(() => DataSync().uploadData());
  configureRuntimeComicSourcesProvider(
    () => WebDavLibraryConfig.fromSettings().isValid
        ? [WebDavLibrarySource.create()]
        : const [],
  );
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
    tileStateResolver: _resolveComicTileState,
    tileImageProviderResolver: _resolveComicTileImageProvider,
    addStateListener: (listener) {
      HistoryManager().addListener(listener);
      LocalFavoritesManager().addListener(listener);
    },
    removeStateListener: (listener) {
      HistoryManager().removeListener(listener);
      LocalFavoritesManager().removeListener(listener);
    },
    favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
      isGallery: isFavoriteGalleryMode(),
      galleryColumns: favoriteGalleryColumns(),
    ),
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
  final dataSync = DataSync();
  startBangumiAfterDataSync(
    waitForDownload: dataSync.waitForDownload,
    createInitializer: () => BangumiService().initialize,
  );
  WebDavLibrarySource.initializeAutoSync();
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

ComicTileState _resolveComicTileState(Comic comic) {
  final type = _comicTypeOf(comic);
  final history = appdata.settings['showHistoryStatusOnTile']
      ? HistoryManager().find(comic.id, type)
      : null;
  return ComicTileState(
    isFavorite:
        appdata.settings['showFavoriteStatusOnTile'] &&
        LocalFavoritesManager().isExist(comic.id, type),
    historyPage: history?.page,
    historyMaxPage: history?.maxPage,
    hasNewUpdate:
        appdata.settings['showUpdateStatusOnTile'] &&
        type != ComicType.local &&
        LocalFavoritesManager().hasNewUpdate(comic.id, type),
  );
}

ComicType _comicTypeOf(Comic comic) {
  if (comic is FavoriteItem) return comic.type;
  if (comic is History) return comic.type;
  if (comic is LocalComic) return comic.comicType;
  return ComicType.fromKey(comic.sourceKey);
}

ImageProvider? _resolveComicTileImageProvider(Comic comic) {
  if (comic.cover.trim().isEmpty) return null;
  if (comic is LocalComic) return LocalComicImageProvider(comic);
  if (comic is History) return HistoryImageProvider(comic);
  if (comic.sourceKey == 'local') {
    final localComic = LocalManager().find(comic.id, ComicType.local);
    return localComic == null ? null : FileImage(localComic.coverFile);
  }
  return CachedImageProvider(
    comic.cover,
    sourceKey: comic.sourceKey,
    cid: comic.id,
    fallback: comic is FavoriteItem
        ? () => _loadLocalCoverFallback(comic.sourceKey, comic.id)
        : null,
  );
}

Future<Uint8List?> _loadLocalCoverFallback(String sourceKey, String id) async {
  final localComic = LocalManager().find(id, ComicType.fromKey(sourceKey));
  if (localComic == null) return null;
  final file = localComic.coverFile;
  if (!await file.exists()) return null;
  final data = await file.readAsBytes();
  return data.isEmpty ? null : data;
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
