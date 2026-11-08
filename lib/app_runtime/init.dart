import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_widgets/comic_widgets.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/history.dart';
import 'package:venera_next/features/local_comics/local_comics.dart';
import 'package:venera_next/features/settings/settings.dart';
import 'package:venera_next/foundation/image_provider/cached_image.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_preferences.dart';
import 'package:venera_next/foundation/global_preference_store.dart';
import 'package:venera_next/foundation/keyword_settings_store.dart';

import 'core_bootstrap.dart';

/// Interactive startup uses the caller-owned, idempotent core bootstrap.
Future<void> init(CoreBootstrap core) async {
  await core.start();
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
    keywordRuleEditor: (context, rule) => showKeywordRuleEditor(
      context,
      target: BlockedKeywordList.comics,
      rule: rule,
    ),
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
      isGallery:
          (GlobalPreferenceStore(
            appdata.settings,
          ).read(FavoritePreferences.displayMode) ==
          'gallery'),
      galleryColumns: GlobalPreferenceStore(
        appdata.settings,
      ).read(FavoritePreferences.galleryColumns),
    ),
  );
  if (App.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
}

ComicTileState _resolveComicTileState(Comic comic) {
  final type = _comicTypeOf(comic);
  final preferences = GlobalPreferenceStore(appdata.settings);
  final showHistory = preferences.read(
    DiscoveryPreferences.showHistoryStatusOnTile,
  );
  final showTotals = preferences.read(
    DiscoveryPreferences.showDetailedReadingProgress,
  );
  final history = comic is History
      ? comic
      : showHistory
      ? HistoryManager().find(comic.id, type)
      : null;
  final description = history?.progressDescription(showTotals: showTotals);
  return ComicTileState(
    isFavorite:
        preferences.read(DiscoveryPreferences.showFavoriteStatusOnTile) &&
        LocalFavoritesManager().isExist(comic.id, type),
    historyPage: showHistory ? history?.page : null,
    historyMaxPage: showHistory ? history?.maxPage : null,
    historyDescription: showHistory ? description : null,
    historyTooltipDescription:
        showTotals && history?.chapterTitle?.trim().isNotEmpty == true
        ? '${history!.description}\n$description'
        : null,
    historyCompactDescription: showTotals
        ? history?.progressDescription(showTotals: true, compact: true)
        : null,
    descriptionOverride: comic is History && showTotals ? description : null,
    hasNewUpdate:
        preferences.read(DiscoveryPreferences.showUpdateStatusOnTile) &&
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

void reloadComicSourcesForDebug() async {
  try {
    await ComicSourceManager().reloadForDebug();
  } catch (error, stack) {
    Log.error('Reload comic sources', error, stack);
    final context = appNavigation.rootNavigatorKey.currentContext;
    if (context != null && context.mounted) {
      showToast(message: error.toString(), context: context);
    }
  }
}
