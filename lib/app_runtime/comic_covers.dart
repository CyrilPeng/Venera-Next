import 'package:venera_next/features/comic_source/comic_metadata.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/features/history/history_manager.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/comic_cover.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/network/request_scope.dart';

Future<void> Function(String, void Function()) _captureWrite(
  ComicCoverIdentity identity,
  RequestScope? request,
) {
  final source = ComicSource.find(identity.sourceKey);
  final favorites = LocalFavoritesManager.cache;
  final history = HistoryManager.cache;
  final type = ComicType.fromKey(identity.sourceKey);
  final saveFavorites = favorites?.captureCoverUpdate(identity.id, type);
  final item = history?.isInitialized == true
      ? history!.find(identity.id, type)
      : null;
  void Function()? activeCheck;
  final saveHistory = item == null
      ? null
      : history!.metadataUpdaterFor(
          item,
          checkActive: () => activeCheck?.call(),
        );
  return (cover, checkActive) async {
    void check() {
      request?.check();
      checkActive();
      if (source == null ||
          !identical(ComicSource.find(identity.sourceKey), source)) {
        throw const RequestCancelled();
      }
    }

    check();
    activeCheck = check;
    try {
      await saveFavorites?.call(cover, check);
      check();
      if (item?.cover != cover) {
        await saveHistory?.call(cover: cover);
      }
      check();
    } finally {
      activeCheck = null;
    }
  };
}

ComicCoverManager initializeComicCovers(CacheManager cache) {
  final manager = ComicCoverManager(
    cache: cache,
    captureOwner: (identity) {
      final source = ComicSource.find(identity.sourceKey);
      final favorites = LocalFavoritesManager.cache;
      final history = HistoryManager.cache;
      final favoriteGeneration = favorites?.connectionGeneration;
      final historyGeneration = history?.connectionGeneration;
      return () {
        if (source == null ||
            !identical(ComicSource.find(identity.sourceKey), source) ||
            favorites?.connectionGeneration != favoriteGeneration ||
            history?.connectionGeneration != historyGeneration) {
          throw const RequestCancelled();
        }
      };
    },
    loadMetadata: (identity, scope) async {
      final source = ComicSource.find(identity.sourceKey);
      final load = source?.loadComicInfo;
      if (load == null) return null;
      final publish = _captureWrite(identity, scope);
      final response = await load(identity.id);
      scope.check();
      if (!identical(ComicSource.find(identity.sourceKey), source)) {
        throw const RequestCancelled();
      }
      if (response.error) {
        final failure = response.failure;
        if (failure != null) {
          Error.throwWithStackTrace(
            failure,
            failure.stackTrace ?? StackTrace.current,
          );
        }
        throw StateError(response.errorMessage ?? 'Comic metadata unavailable');
      }
      return ComicCoverMetadata(response.data.cover, publish);
    },
  );
  ComicCoverManager.instance = manager;
  configureComicMetadataPublication((sourceKey, id) {
    if (ComicCoverManager.isRefreshingMetadata || sourceKey == 'local') {
      return null;
    }
    final identity = ComicCoverIdentity(sourceKey, id);
    return manager.captureMetadata(
      identity,
      _captureWrite(identity, RequestScope.current),
    );
  });
  return manager;
}

Future<void> closeComicCovers(ComicCoverManager manager) async {
  configureComicMetadataPublication();
  await manager.dispose();
}
