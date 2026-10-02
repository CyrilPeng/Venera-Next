import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/features/webdav_library/webdav_library_config.dart';
import 'package:venera_next/features/webdav_library/webdav_library_settings.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';

import 'webdav_library_discovery.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_snapshot.dart';
import 'webdav_library_snapshot_builder.dart';
import 'webdav_library_transport.dart';

class WebDavLibrarySyncStatus {
  const WebDavLibrarySyncStatus({
    required this.isSyncing,
    required this.lastSuccessfulSync,
    this.processed = 0,
    this.total = 0,
    this.failed = 0,
    this.errorMessage,
  });

  final bool isSyncing;
  final int lastSuccessfulSync;
  final int processed;
  final int total;
  final int failed;
  final String? errorMessage;

  String get formattedLastSuccessfulSync {
    if (lastSuccessfulSync <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(lastSuccessfulSync);
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
        '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
  }
}

class _WebDavLibrarySyncRun {
  const _WebDavLibrarySyncRun({
    required this.indexReady,
    required this.complete,
  });

  final Future<Res<bool>> indexReady;
  final Future<Res<bool>> complete;
}

class WebDavLibrarySource {
  WebDavLibrarySource({
    required WebDavLibrarySettings Function() readSettings,
    required WebDavLibraryCache cache,
    WebDavLibraryOps? ops,
  }) : _readSettings = readSettings,
       _cache = cache,
       _ops = ops ?? WebDavHttpLibraryOps();

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
  static const rootChapterTitle = webDavRootChapterTitle;

  final _snapshotCache = <String, WebDavComicSnapshot>{};
  final _snapshotInFlight = <String, Future<WebDavComicSnapshot>>{};
  final contentVersion = ValueNotifier<int>(0);
  final syncStatus = ValueNotifier<WebDavLibrarySyncStatus>(
    const WebDavLibrarySyncStatus(isSyncing: false, lastSuccessfulSync: 0),
  );
  _WebDavLibrarySyncRun? _syncRun;

  void _clearMemoryCaches() {
    _snapshotCache.clear();
    _snapshotInFlight.clear();
  }

  void onConfigurationChanged(WebDavLibraryConfig previous) {
    if (_disposed) return;
    _session?.cancel();
    _session = null;
    _syncRun = null;
    _clearMemoryCaches();
    if (previous.isValid) {
      _cache.clear(previous.cacheKey);
    }
    syncStatus.value = const WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: 0,
    );
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
    _syncRun = null;
    _clearMemoryCaches();
    try {
      _ops.dispose();
    } finally {
      try {
        _cache.dispose();
      } finally {
        contentVersion.dispose();
        syncStatus.dispose();
      }
    }
  }

  void updateSyncStatusFromCache() {
    if (_disposed) return;
    final session = _currentSession();
    if (syncStatus.value.isSyncing) return;
    final config = session.config;
    if (!config.isValid) return;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    if (syncStatus.value.lastSuccessfulSync == lastSync) return;
    syncStatus.value = WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: lastSync,
    );
  }

  void checkForAutomaticSync() {
    if (_disposed) return;
    updateSyncStatusFromCache();
    final configuration = _readSettings();
    final config = configuration.connection;
    if (!config.isValid || !configuration.autoSync) {
      return;
    }
    final interval = configuration.intervalMinutes;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    final elapsed = DateTime.now().millisecondsSinceEpoch - lastSync;
    if (lastSync == 0 ||
        elapsed >= Duration(minutes: interval).inMilliseconds) {
      unawaited(synchronize());
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
            await synchronize(force: true);
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
      final indexResult = await _ensureIndex(session);
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
      checkForAutomaticSync();
      return Res(comics, subData: maxPage);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<Res<bool>> _ensureIndex(WebDavLibrarySession session) async {
    session.check();
    final config = session.config;
    if (_cache.hasDirectoryIndex(config.cacheKey)) {
      checkForAutomaticSync();
      return const Res(true);
    }
    return (await _startSynchronization(session: session).indexReady);
  }

  Future<Res<bool>> synchronize({bool force = false}) {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return Future.value(
        const Res.error('Invalid WebDAV comic library configuration'),
      );
    }
    return _startSynchronization(session: session, force: force).complete;
  }

  _WebDavLibrarySyncRun _startSynchronization({
    required WebDavLibrarySession session,
    bool force = false,
  }) {
    final current = _syncRun;
    if (current != null) return current;

    final indexReady = Completer<Res<bool>>();
    final complete = Future<Res<bool>>.microtask(
      () => _runSynchronization(session, indexReady, force: force),
    );
    final run = _WebDavLibrarySyncRun(
      indexReady: indexReady.future,
      complete: complete,
    );
    _syncRun = run;
    unawaited(
      complete.whenComplete(() {
        if (identical(_syncRun, run)) {
          _syncRun = null;
        }
      }),
    );
    return run;
  }

  Future<Res<bool>> _runSynchronization(
    WebDavLibrarySession session,
    Completer<Res<bool>> indexReady, {
    required bool force,
  }) async {
    final config = session.config;
    final configKey = config.cacheKey;
    var previousLastSync = 0;
    try {
      session.check();
      previousLastSync = _cache.lastSuccessfulSync(configKey);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: true,
        lastSuccessfulSync: previousLastSync,
      );
      final rootEntries = List<WebDavLibraryEntry>.from(
        await session.readDir(config.remotePath),
      );
      session.check();
      final hadDirectoryIndex = _cache.hasDirectoryIndex(configKey);
      final previous = _cache.all(configKey);
      final provisionalDirectories = webDavSortedDirectories(rootEntries);
      if (!hadDirectoryIndex) {
        _cache.replaceDirectoryIndex(configKey, [
          for (var index = 0; index < provisionalDirectories.length; index++)
            WebDavLibraryRemoteDirectory(
              id: provisionalDirectories[index].name,
              sortIndex: index,
              eTag: provisionalDirectories[index].eTag,
              modifiedAt: provisionalDirectories[index].modifiedAt,
            ),
        ]);
      }
      if (!indexReady.isCompleted) {
        indexReady.complete(const Res(true));
      }
      contentVersion.value++;
      final discovered = await WebDavLibraryDiscovery(session).discover(
        rootEntries: rootEntries,
        canReuse: (directory) {
          final cached = previous[directory.name];
          return !force &&
              cached != null &&
              cached.isReady &&
              cached.hasSameRemoteVersion(
                eTag: directory.eTag,
                modifiedAt: directory.modifiedAt,
              );
        },
      );
      session.check();
      final remoteDirectories = <WebDavLibraryRemoteDirectory>[
        for (var index = 0; index < discovered.length; index++)
          WebDavLibraryRemoteDirectory(
            id: discovered[index].id,
            sortIndex: index,
            eTag: discovered[index].eTag,
            modifiedAt: discovered[index].modifiedAt,
          ),
      ];
      _cache.replaceDirectoryIndex(configKey, remoteDirectories);
      contentVersion.value++;

      final toRefresh = <WebDavLibraryRemoteDirectory>[];
      for (final directory in remoteDirectories) {
        final cached = previous[directory.id];
        if (force ||
            !hadDirectoryIndex ||
            cached == null ||
            !cached.isReady ||
            !cached.hasSameRemoteVersion(
              eTag: directory.eTag,
              modifiedAt: directory.modifiedAt,
            )) {
          toRefresh.add(directory);
        }
      }

      session.check();
      var processed = 0;
      var failed = 0;
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: true,
        lastSuccessfulSync: previousLastSync,
        total: toRefresh.length,
      );
      await runThrottledTasks(
        toRefresh,
        concurrency: 4,
        throttleEvery: 0,
        run: (directory) async {
          try {
            final discoveredDirectory = discovered.firstWhere(
              (candidate) => candidate.id == directory.id,
            );
            await _loadSnapshot(
              session,
              directory.id,
              forceRefresh: true,
              remoteDirectory: directory,
              rootEntries: discoveredDirectory.entries,
            );
          } catch (e) {
            if (e is WebDavLibraryCancelled) rethrow;
            failed++;
            Log.warning(
              'WebDAV Library',
              'Failed to inspect ${directory.id}: $e',
            );
          } finally {
            processed++;
            if (session.isActive &&
                (processed % 5 == 0 || processed == toRefresh.length)) {
              contentVersion.value++;
              session.check();
              syncStatus.value = WebDavLibrarySyncStatus(
                isSyncing: true,
                lastSuccessfulSync: previousLastSync,
                processed: processed,
                total: toRefresh.length,
                failed: failed,
              );
            }
          }
        },
      );

      session.check();
      final now = DateTime.now().millisecondsSinceEpoch;
      _cache.setLastSuccessfulSync(configKey, now);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: now,
        processed: processed,
        total: toRefresh.length,
        failed: failed,
      );
      session.check();
      contentVersion.value++;
      return const Res(true);
    } catch (e, s) {
      if (!session.isActive) {
        const result = Res<bool>.error('WebDAV request cancelled');
        if (!indexReady.isCompleted) indexReady.complete(result);
        return result;
      }
      Log.error('WebDAV Library Sync', e, s);
      final result = Res<bool>.error(e.toString());
      if (!indexReady.isCompleted) {
        indexReady.complete(result);
      }
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: previousLastSync,
        errorMessage: e.toString(),
      );
      return result;
    }
  }

  Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final snapshot = await _loadSnapshot(session, id);
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

      final snapshot = await _loadSnapshot(session, id);
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

  Future<WebDavComicSnapshot> _loadSnapshot(
    WebDavLibrarySession session,
    String id, {
    bool forceRefresh = false,
    WebDavLibraryRemoteDirectory? remoteDirectory,
    List<WebDavLibraryEntry>? rootEntries,
  }) async {
    session.check();
    final config = session.config;
    final memoryKey = jsonEncode([config.cacheKey, id]);
    if (!forceRefresh) {
      final memoryCached = _snapshotCache[memoryKey];
      if (memoryCached != null) return memoryCached;
      final diskCached = _cache.find(config.cacheKey, id);
      if (diskCached?.isReady == true) {
        final snapshot = WebDavComicSnapshot.fromJson(diskCached!.snapshot!);
        _snapshotCache[memoryKey] = snapshot;
        return snapshot;
      }
    }

    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) return inFlight;
    final future = () async {
      final snapshot = await WebDavLibrarySnapshotBuilder(
        session,
      ).build(id, rootEntries: rootEntries);
      session.check();
      final existing = _cache.find(config.cacheKey, id);
      _cache.upsertSnapshot(
        config.cacheKey,
        WebDavLibraryCachedComic(
          id: id,
          sortIndex: remoteDirectory?.sortIndex ?? existing?.sortIndex ?? 0,
          title: snapshot.title,
          author: snapshot.author,
          tags: snapshot.tags,
          cover: snapshot.cover,
          snapshot: snapshot.toJson(),
          remoteETag: remoteDirectory?.eTag ?? existing?.remoteETag,
          remoteModifiedAt:
              remoteDirectory?.modifiedAt ?? existing?.remoteModifiedAt,
        ),
      );
      _snapshotCache[memoryKey] = snapshot;
      return snapshot;
    }();
    _snapshotInFlight[memoryKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_snapshotInFlight[memoryKey], future)) {
        _snapshotInFlight.remove(memoryKey);
      }
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
