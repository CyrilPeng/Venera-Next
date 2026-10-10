import 'package:venera_next/foundation/operation_failure.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/network/images.dart';
import 'package:venera_next/network/image_stream.dart';
import 'package:venera_next/network/request_scope.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/features/history/image_favorites_models.dart';
import 'image_favorites_cache.dart';

class ImageFavoritesProvider extends BaseImageProvider<ImageFavoritesProvider> {
  /// Image provider for imageFavorites
  const ImageFavoritesProvider(
    this.imageFavorite, {
    ComicImageLoader loadImage = ImageDownloader.loadComicImage,
  }) : _loadImage = loadImage;

  final ImageFavorite imageFavorite;
  final ComicImageLoader _loadImage;

  int get page => imageFavorite.page;

  String get sourceKey => imageFavorite.sourceKey;

  String get cid => imageFavorite.id;

  String get eid => imageFavorite.eid;

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    final stop = checkStop ?? () {};
    return readBytes(
      checkStop: stop,
      cancelSignal: BaseImageProvider.cancelSignalOf(stop),
      onProgress: chunkEvents?.add,
    );
  }

  /// Reads original bytes for both display and an explicitly owned save action.
  /// Cancellation stops the next stage and joins the accepted source/file work.
  Future<Uint8List> readBytes({
    required void Function() checkStop,
    required Future<void> cancelSignal,
    void Function(ImageChunkEvent)? onProgress,
  }) async {
    checkStop();
    final scope = RequestScope(parent: RequestScope.current);
    var finished = false;
    unawaited(
      cancelSignal.then((_) {
        if (finished) return;
        try {
          checkStop();
        } catch (error) {
          scope.cancel(error);
          return;
        }
        scope.cancel();
      }),
    );
    void stop() {
      checkStop();
      scope.check();
    }

    try {
      return await runZoned(
        () => scope.runToCompletion(() => _readBytes(stop)),
        zoneValues: {
          _readContextKey: _FavoriteReadContext(
            scope.whenCancelled,
            onProgress,
          ),
        },
      );
    } finally {
      finished = true;
      scope.dispose();
    }
  }

  static final _readContextKey = Object();

  Future<Uint8List> _readBytes(void Function() stop) async {
    stop();
    _checkPage();
    var imageKey = imageFavorite.imageKey;
    var localImage = await getImageFromLocal(checkStop: stop);
    stop();
    if (localImage != null) {
      return localImage;
    }
    var cacheImage = await readFromCache();
    stop();
    if (cacheImage != null) {
      return cacheImage;
    }
    var gotImageKey = false;
    if (imageKey.isEmpty || eid.isEmpty) {
      imageKey = await getImageKey();
      stop();
      gotImageKey = true;
    }
    Uint8List image;
    try {
      image = await getImageFromNetwork(imageKey, null, stop);
    } catch (e) {
      if (gotImageKey ||
          BaseImageProvider.isCancellation(e) ||
          BaseImageProvider.isCleanupFailure(e) ||
          !BaseImageProvider.canRetryAfterFailure(stop)) {
        rethrow;
      } else {
        imageKey = await getImageKey();
        stop();
        image = await getImageFromNetwork(imageKey, null, stop);
      }
    }
    stop();
    await writeToCache(image);
    stop();
    return image;
  }

  Future<void> writeToCache(Uint8List image) async {
    final file = imageFavoriteCacheFile(key);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    await file.writeAsBytes(image);
  }

  Future<Uint8List?> readFromCache() async {
    final file = imageFavoriteCacheFile(key);
    if (!file.existsSync()) {
      return null;
    }
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      // Cache eviction may finish after the existence check above.
      // A vanished entry is a miss; retain errors for entries still present.
      if (!file.existsSync()) return null;
      rethrow;
    }
  }

  Future<Uint8List?> getImageFromLocal({void Function()? checkStop}) async {
    checkStop?.call();
    _checkPage();
    final manager = LocalManager();
    final type = ComicType.fromKey(sourceKey);
    final localComic = manager.find(cid, type);
    if (localComic == null) {
      return null;
    }
    Object chapter = imageFavorite.ep;
    if (localComic.chapters case final chapters?) {
      // Only imported records without an ID use their one-based ordinal.
      // A missing known ID must never select another chapter after a reorder.
      final chapterId = eid.isNotEmpty
          ? (chapters.ids.contains(eid) ? eid : null)
          : (imageFavorite.ep > 0
                ? chapters.ids.elementAtOrNull(imageFavorite.ep - 1)
                : null);
      if (chapterId == null ||
          (type != ComicType.local &&
              !localComic.downloadedChapters.contains(chapterId))) {
        return null;
      }
      chapter = chapterId;
    }
    try {
      final images = await manager.getImages(cid, type, chapter);
      checkStop?.call();
      if (page > images.length) return null;
      final path = images[page - 1];
      final data = await File(
        path.startsWith('file://') ? path.substring(7) : path,
      ).readAsBytes();
      checkStop?.call();
      return data;
    } on FileSystemException catch (error) {
      if (checkStop != null &&
          !BaseImageProvider.canRetryAfterFailure(checkStop)) {
        rethrow;
      }
      // Missing downloaded storage may recover online. Permission and other
      // read failures keep their original diagnostics instead of being hidden.
      if (type != ComicType.local &&
          (error is PathNotFoundException ||
              error.osError?.errorCode == 2 ||
              (Platform.isWindows && error.osError?.errorCode == 3))) {
        return null;
      }
      rethrow;
    }
  }

  Future<Uint8List> getImageFromNetwork(
    String imageKey,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
  ) async {
    final stop = checkStop ?? () {};
    stop();
    final context = Zone.current[_readContextKey] as _FavoriteReadContext?;
    final bytes = await readImageStream(
      loadComicImage(imageKey),
      cancelSignal:
          context?.cancelSignal ?? BaseImageProvider.cancelSignalOf(stop),
      checkStop: stop,
      onProgress: (progress) {
        final event = ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        );
        if (context != null) {
          context.onProgress?.call(event);
        } else {
          chunkEvents?.add(event);
        }
      },
    );
    stop();
    if (bytes == null) {
      throw OperationFailure.message("Error: Empty response body.");
    }
    return bytes;
  }

  @protected
  Stream<ImageDownloadProgress> loadComicImage(String imageKey) {
    final context = Zone.current[_readContextKey] as _FavoriteReadContext?;
    return _loadImage(imageKey, sourceKey, cid, context?.imageChapterId ?? eid);
  }

  Future<String> getImageKey() async {
    _checkPage();
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null) {
      throw StateError('Comic source not found: $sourceKey');
    }
    final loadPages = comicSource.loadComicPages;
    if (loadPages == null) {
      throw UnsupportedError('Comic source does not support loading pages');
    }
    String? chapterId = eid;
    if (eid.isEmpty) {
      final loadInfo = comicSource.loadComicInfo;
      if (loadInfo == null) {
        throw UnsupportedError(
          'Comic source cannot resolve an imported chapter',
        );
      }
      final details = _sourceData(await loadInfo(cid));
      RequestScope.current?.check();
      final chapters = details.chapters;
      final ep = imageFavorite.ep;
      if (ep < 1 || ep > (chapters?.length ?? 1)) {
        throw RangeError.range(ep, 1, chapters?.length ?? 1, 'ep');
      }
      chapterId = chapters?.ids.elementAt(ep - 1);
    }
    final context = Zone.current[_readContextKey] as _FavoriteReadContext?;
    // Pages use null for a chapterless source; image loading follows the reader's
    // existing synthetic chapter ID convention without changing stored identity.
    context?.imageChapterId = chapterId ?? '0';
    final images = _sourceData(await loadPages(cid, chapterId));
    RequestScope.current?.check();
    if (page > images.length) {
      throw RangeError.range(page, 1, images.length, 'page');
    }
    return images[page - 1];
  }

  T _sourceData<T>(Res<T> res) {
    if (res.error) {
      final failure = res.failure;
      if (failure != null) {
        final cause = failure.cause ?? failure;
        final stack = failure.stackTrace;
        if (stack != null) Error.throwWithStackTrace(cause, stack);
        throw cause;
      }
      res.throwIfError();
    }
    return res.data;
  }

  void _checkPage() {
    if (page < 1) throw RangeError.range(page, 1, null, 'page');
  }

  @override
  Future<ImageFavoritesProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => imageFavoriteCacheKey(imageFavorite);
}

class _FavoriteReadContext {
  _FavoriteReadContext(this.cancelSignal, this.onProgress);
  final Future<void> cancelSignal;
  final void Function(ImageChunkEvent)? onProgress;
  String? imageChapterId;
}
