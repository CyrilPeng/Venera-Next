import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/features/webdav_library/webdav_library_config.dart';
import 'package:venera_next/features/webdav_library/webdav_library_settings.dart';
import 'package:venera_next/foundation/res.dart';

import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_transport.dart';
import 'webdav_library_snapshot_store.dart';
import 'webdav_library_synchronizer.dart';

class WebDavLibrarySource {
  WebDavLibrarySource({
    required WebDavLibrarySettings Function() readSettings,
    required WebDavLibraryCache cache,
    WebDavLibraryOps? ops,
  }) : _readSettings = readSettings,
       _cache = cache,
       _ops = ops ?? WebDavHttpLibraryOps() {
    _snapshots = WebDavLibrarySnapshotStore(cache);
    synchronizer = WebDavLibrarySynchronizer(
      cache: cache,
      snapshots: _snapshots,
      readSettings: readSettings,
      currentSession: _currentSession,
      onContentChanged: () {
        if (!_disposed) contentVersion.value++;
      },
    );
  }

  final WebDavLibrarySettings Function() _readSettings;
  final WebDavLibraryCache _cache;
  final WebDavLibraryOps _ops;
  WebDavLibrarySession? _session;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  static const sourceKey = 'webdav_library';
  static const explorePageTitle = 'WebDAV Library';
  static const pageSize = 20;
  static const rootChapterId = webDavRootChapterId;

  final contentVersion = ValueNotifier<int>(0);
  late final WebDavLibrarySnapshotStore _snapshots;
  late final WebDavLibrarySynchronizer synchronizer;

  void onConfigurationChanged(WebDavLibraryConfig previous) {
    if (_disposed) return;
    _session?.cancel();
    _session = null;
    try {
      if (previous.isValid) {
        _cache.clear(previous.cacheKey);
      }
    } finally {
      synchronizer.invalidate();
    }
    if (!_disposed) contentVersion.value++;
  }

  WebDavLibrarySession _currentSession() {
    if (_disposed) throw StateError('WebDAV library is disposed');
    final config = _readSettings().connection;
    final previous = _session;
    if (previous != null &&
        previous.config.connectionKey != config.connectionKey) {
      onConfigurationChanged(previous.config);
    }
    return _session ??= WebDavLibrarySession(
      config,
      _ops,
      isCurrent: () =>
          !_disposed &&
          _readSettings().connection.connectionKey == config.connectionKey,
    );
  }

  /// Cancels ownership immediately; late transport completions cannot commit.
  /// The source owns its injected cache and transport for its entire lifetime.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session?.cancel();
    synchronizer.dispose();
    try {
      _ops.dispose();
    } finally {
      try {
        _cache.dispose();
      } finally {
        contentVersion.dispose();
      }
    }
  }

  ComicSource create() {
    return ComicSource(
      'WebDAV Library',
      sourceKey,
      null,
      null,
      null,
      null,
      [
        ExplorePageData(
          explorePageTitle,
          ExplorePageType.multiPageComicList,
          loadComics,
          null,
          null,
          null,
          changeListenable: contentVersion,
          onRefresh: () async {
            await synchronizer.synchronize(force: true);
          },
        ),
      ],
      null,
      null,
      loadComicInfo,
      null,
      loadComicPages,
      getImageLoadingConfig,
      getThumbnailLoadingConfig,
      '',
      '',
      '',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  Future<Res<bool>> testConnection(WebDavLibraryConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      if (_disposed) throw StateError('WebDAV library is disposed');
      await _ops.test(config);
      if (_disposed) throw StateError('WebDAV library is disposed');
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<List<Comic>>> loadComics(int page) async {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      if (page < 1) return const Res([], subData: 1);
      final indexResult = await synchronizer.ensureIndex(session);
      if (indexResult.error) {
        return Res.error(indexResult.errorMessage!);
      }
      session.check();
      final count = _cache.count(config.cacheKey);
      final maxPage = count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize;
      if (page > maxPage) return Res([], subData: maxPage);
      final comics = _cache
          .page(config.cacheKey, page: page, pageSize: pageSize)
          .map(
            (comic) => Comic(
              comic.title,
              comic.cover,
              comic.id,
              comic.author,
              <String>{'WebDAV', ...comic.tags}.toList(),
              '',
              sourceKey,
              null,
              null,
            ),
          )
          .toList();
      synchronizer.checkForAutomaticSync();
      return Res(comics, subData: maxPage);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final snapshot = await _snapshots.load(session, id);
      session.check();
      return Res(
        ComicDetails.fromJson({
          'title': snapshot.title,
          'subtitle': snapshot.author,
          'cover': snapshot.cover,
          'description': '',
          'tags': snapshot.detailTags,
          'chapters':
              snapshot.chapters.length == 1 &&
                  snapshot.chapters.containsKey(rootChapterId)
              ? null
              : snapshot.chapters,
          'sourceKey': sourceKey,
          'comicId': id,
          'thumbnails': null,
          'recommend': null,
          'isFavorite': false,
          'subId': null,
          'likesCount': null,
          'isLiked': null,
          'commentCount': null,
          'uploader': null,
          'uploadTime': null,
          'updateTime': null,
          'url': null,
          'maxPage': null,
        }),
      );
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final comicPath = config.childDirectoryPath(id);
      if (ep != null &&
          ep != rootChapterId &&
          !ep.startsWith(webDavMetadataChapterPrefix)) {
        final path = config.childDirectoryPathFrom(comicPath, ep);
        final entries = List<WebDavLibraryEntry>.from(
          await session.readDir(path),
        );
        session.check();
        final files = webDavImageEntries(entries)
            .where((entry) => !isNamedComicCover(entry.name))
            .map((entry) => config.childFilePath(path, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the WebDAV chapter');
        }
        return Res(files);
      }

      final snapshot = await _snapshots.load(session, id);
      session.check();
      final metadataChapter = ep == null ? null : snapshot.metadataChapters[ep];
      if (metadataChapter != null) {
        final files = snapshot.rootImages
            .sublist(metadataChapter.start - 1, metadataChapter.end)
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        return Res(files);
      }
      if (ep?.startsWith(webDavMetadataChapterPrefix) == true) {
        return const Res.error('Invalid WebDAV metadata chapter');
      }
      if (ep == null || ep == rootChapterId) {
        final files = snapshot.rootImages
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the WebDAV chapter');
        }
        return Res(files);
      }
      return const Res.error('No images found in the WebDAV chapter');
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Map<String, dynamic>> getImageLoadingConfig(
    String imageKey,
    String comicId,
    String epId,
  ) async {
    final session = _currentSession();
    final config = session.config;
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  Map<String, dynamic> getThumbnailLoadingConfig(String imageKey) {
    final session = _currentSession();
    final config = session.config;
    if (imageKey.startsWith('cover.')) {
      return {'headers': config.authHeaders};
    }
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }
}
