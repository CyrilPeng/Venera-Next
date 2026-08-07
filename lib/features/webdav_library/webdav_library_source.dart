import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/extensions.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';
import 'package:venera_next/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

class WebDavLibraryConfig {
  WebDavLibraryConfig({
    required String url,
    required String user,
    required String pass,
    required String remotePath,
  }) : endpoint = WebDavEndpoint(url: url, user: user, password: pass),
       remotePath = normalizeWebDavDirectoryPath(
         remotePath,
         fallback: '/venera_comics/',
       );

  final WebDavEndpoint endpoint;
  final String remotePath;

  String get url => endpoint.url;

  String get user => endpoint.user;

  String get pass => endpoint.password;

  bool get isValid => endpoint.isValid;

  Map<String, String> get authHeaders => endpoint.authHeaders;

  String get cacheKey => jsonEncode([url, user, remotePath]);

  String get connectionKey => jsonEncode([url, user, pass, remotePath]);

  static WebDavLibraryConfig fromSettings() {
    final config = appdata.settings['webdavComicLibrary'];
    final path = appdata.settings['webdavComicLibraryPath'];
    if (config is List && config.whereType<String>().length == 3) {
      final values = config.whereType<String>().toList();
      return WebDavLibraryConfig(
        url: values[0],
        user: values[1],
        pass: values[2],
        remotePath: path is String ? path : '/venera_comics/',
      );
    }
    return WebDavLibraryConfig(
      url: '',
      user: '',
      pass: '',
      remotePath: path is String ? path : '/venera_comics/',
    );
  }

  static Future<void> saveToSettings(WebDavLibraryConfig config) async {
    final previous = fromSettings();
    if (!config.isValid && config.user.isEmpty && config.pass.isEmpty) {
      appdata.settings['webdavComicLibrary'] = [];
    } else {
      appdata.settings['webdavComicLibrary'] = [
        config.url,
        config.user,
        config.pass,
      ];
    }
    appdata.settings['webdavComicLibraryPath'] = config.remotePath;
    await appdata.saveData(false);
    if (previous.connectionKey != config.connectionKey) {
      WebDavLibrarySource.onConfigurationChanged(previous);
    }
  }

  String childDirectoryPath(String name) {
    return childDirectoryPathFrom(remotePath, name);
  }

  String childFilePath(String parent, String name) {
    return joinWebDavFilePath(parent, name);
  }

  String childDirectoryPathFrom(String parent, String name) {
    return joinWebDavDirectoryPath(parent, name);
  }

  String fileUrl(String remoteFilePath) => endpoint.fileUrl(remoteFilePath);
}

class WebDavLibraryEntry {
  const WebDavLibraryEntry({
    required this.name,
    required this.isDirectory,
    this.eTag,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final String? eTag;
  final int? modifiedAt;
}

abstract class WebDavLibraryOps {
  Future<void> test(WebDavLibraryConfig config);

  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  );

  Future<String> readText(WebDavLibraryConfig config, String remotePath);
}

class _WebDavLibraryOps implements WebDavLibraryOps {
  final _clients = <String, Client>{};

  Client _client(WebDavLibraryConfig config) {
    return _clients.putIfAbsent(
      config.connectionKey,
      config.endpoint.createClient,
    );
  }

  @override
  Future<void> test(WebDavLibraryConfig config) async {
    await _client(config).readDir(config.remotePath);
  }

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async {
    final entries = await _client(config).readDir(remotePath);
    return entries
        .where((entry) => entry.name != null)
        .map(
          (entry) => WebDavLibraryEntry(
            name: entry.name!,
            isDirectory: entry.isDir == true,
            eTag: entry.eTag?.isEmpty == true ? null : entry.eTag,
            modifiedAt: entry.mTime?.millisecondsSinceEpoch,
          ),
        )
        .toList();
  }

  @override
  Future<String> readText(WebDavLibraryConfig config, String remotePath) async {
    final bytes = await _client(config).read(remotePath);
    return utf8.decode(bytes, allowMalformed: false);
  }
}

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
  const WebDavLibrarySource._();

  static const sourceKey = 'webdav_library';
  static const explorePageTitle = 'WebDAV Library';
  static const pageSize = 20;
  static const rootChapterId = '__root__';
  static const rootChapterTitle = 'Images';
  static const _metadataFileName = 'metadata.json';
  static const _metadataChapterPrefix = '__cbz_range_';
  static const _autoSyncCheckInterval = Duration(minutes: 15);

  static final _snapshotCache = <String, _WebDavComicSnapshot>{};
  static final _snapshotInFlight = <String, Future<_WebDavComicSnapshot>>{};
  static final contentVersion = ValueNotifier<int>(0);
  static final syncStatus = ValueNotifier<WebDavLibrarySyncStatus>(
    const WebDavLibrarySyncStatus(isSyncing: false, lastSuccessfulSync: 0),
  );
  static final _cache = WebDavLibraryCache.instance;
  static WebDavLibraryOps _ops = _WebDavLibraryOps();
  static _WebDavLibrarySyncRun? _syncRun;
  static Timer? _autoSyncTimer;

  static WebDavLibraryOps get ops => _ops;

  static set ops(WebDavLibraryOps value) {
    _ops = value;
    _clearMemoryCaches();
  }

  static void resetOps() {
    _ops = _WebDavLibraryOps();
    _clearMemoryCaches();
  }

  static void _clearMemoryCaches() {
    _snapshotCache.clear();
    _snapshotInFlight.clear();
  }

  static void onConfigurationChanged(WebDavLibraryConfig previous) {
    _clearMemoryCaches();
    _ops = _WebDavLibraryOps();
    if (previous.isValid) {
      _cache.clear(previous.cacheKey);
    }
    contentVersion.value++;
  }

  static void initializeAutoSync() {
    updateSyncStatusFromCache();
    _autoSyncTimer ??= Timer.periodic(
      _autoSyncCheckInterval,
      (_) => checkForAutomaticSync(),
    );
    checkForAutomaticSync();
  }

  static void updateSyncStatusFromCache() {
    if (syncStatus.value.isSyncing) return;
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) return;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    if (syncStatus.value.lastSuccessfulSync == lastSync) return;
    syncStatus.value = WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: lastSync,
    );
  }

  static void checkForAutomaticSync() {
    updateSyncStatusFromCache();
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid ||
        appdata.settings['webdavComicLibraryAutoSync'] != true) {
      return;
    }
    final interval =
        (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
            ?.round() ??
        360;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    final elapsed = DateTime.now().millisecondsSinceEpoch - lastSync;
    if (lastSync == 0 ||
        elapsed >= Duration(minutes: interval).inMilliseconds) {
      unawaited(synchronize());
    }
  }

  @visibleForTesting
  static void resetCacheForTesting() {
    _syncRun = null;
    _clearMemoryCaches();
    _cache.resetForTesting();
    syncStatus.value = const WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: 0,
    );
    contentVersion.value++;
  }

  static ComicSource create() {
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

  static Future<Res<bool>> testConnection(WebDavLibraryConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      await ops.test(config);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<Comic>>> loadComics(int page) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      if (page < 1) return const Res([], subData: 1);
      final indexResult = await _ensureIndex(config);
      if (indexResult.error) {
        return Res.error(indexResult.errorMessage!);
      }
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

  static Future<Res<bool>> _ensureIndex(WebDavLibraryConfig config) async {
    if (_cache.hasDirectoryIndex(config.cacheKey)) {
      checkForAutomaticSync();
      return const Res(true);
    }
    return (await _startSynchronization(config: config).indexReady);
  }

  static Future<Res<bool>> synchronize({bool force = false}) {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return Future.value(
        const Res.error('Invalid WebDAV comic library configuration'),
      );
    }
    return _startSynchronization(config: config, force: force).complete;
  }

  static _WebDavLibrarySyncRun _startSynchronization({
    required WebDavLibraryConfig config,
    bool force = false,
  }) {
    final current = _syncRun;
    if (current != null) return current;

    final indexReady = Completer<Res<bool>>();
    final complete = Future<Res<bool>>.microtask(
      () => _runSynchronization(config, indexReady, force: force),
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

  static Future<Res<bool>> _runSynchronization(
    WebDavLibraryConfig config,
    Completer<Res<bool>> indexReady, {
    required bool force,
  }) async {
    final configKey = config.cacheKey;
    final previousLastSync = _cache.lastSuccessfulSync(configKey);
    syncStatus.value = WebDavLibrarySyncStatus(
      isSyncing: true,
      lastSuccessfulSync: previousLastSync,
    );
    try {
      final entries = List<WebDavLibraryEntry>.from(
        await ops.readDir(config, config.remotePath),
      );
      final directories =
          entries
              .where((entry) => entry.isDirectory)
              .where((entry) => !_isIgnoredEntry(entry.name))
              .toList()
            ..sort((a, b) => compareComicFileNames(a.name, b.name));
      final hadDirectoryIndex = _cache.hasDirectoryIndex(configKey);
      final previous = _cache.all(configKey);
      final remoteDirectories = <WebDavLibraryRemoteDirectory>[
        for (var index = 0; index < directories.length; index++)
          WebDavLibraryRemoteDirectory(
            id: directories[index].name,
            sortIndex: index,
            eTag: directories[index].eTag,
            modifiedAt: directories[index].modifiedAt,
          ),
      ];
      _cache.replaceDirectoryIndex(configKey, remoteDirectories);
      if (!indexReady.isCompleted) {
        indexReady.complete(const Res(true));
      }
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
            await _loadSnapshot(
              config,
              directory.id,
              forceRefresh: true,
              remoteDirectory: directory,
            );
          } catch (e) {
            failed++;
            Log.warning(
              'WebDAV Library',
              'Failed to inspect ${directory.id}: $e',
            );
          } finally {
            processed++;
            if (processed % 5 == 0 || processed == toRefresh.length) {
              contentVersion.value++;
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

      final now = DateTime.now().millisecondsSinceEpoch;
      _cache.setLastSuccessfulSync(configKey, now);
      syncStatus.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: now,
        processed: processed,
        total: toRefresh.length,
        failed: failed,
      );
      contentVersion.value++;
      return const Res(true);
    } catch (e, s) {
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

  static Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final snapshot = await _loadSnapshot(config, id);
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

  static Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    final config = WebDavLibraryConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      final comicPath = config.childDirectoryPath(id);
      if (ep != null &&
          ep != rootChapterId &&
          !ep.startsWith(_metadataChapterPrefix)) {
        final path = config.childDirectoryPathFrom(comicPath, ep);
        final entries = List<WebDavLibraryEntry>.from(
          await ops.readDir(config, path),
        );
        final files = _imageEntries(entries)
            .where((entry) => !isNamedComicCover(entry.name))
            .map((entry) => config.childFilePath(path, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the WebDAV chapter');
        }
        return Res(files);
      }

      final snapshot = await _loadSnapshot(config, id);
      final metadataChapter = ep == null ? null : snapshot.metadataChapters[ep];
      if (metadataChapter != null) {
        final files = snapshot.rootImages
            .sublist(metadataChapter.start - 1, metadataChapter.end)
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        return Res(files);
      }
      if (ep?.startsWith(_metadataChapterPrefix) == true) {
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

  static Future<_WebDavComicSnapshot> _loadSnapshot(
    WebDavLibraryConfig config,
    String id, {
    bool forceRefresh = false,
    WebDavLibraryRemoteDirectory? remoteDirectory,
  }) async {
    final memoryKey = jsonEncode([config.cacheKey, id]);
    if (!forceRefresh) {
      final memoryCached = _snapshotCache[memoryKey];
      if (memoryCached != null) return memoryCached;
      final diskCached = _cache.find(config.cacheKey, id);
      if (diskCached?.isReady == true) {
        final snapshot = _WebDavComicSnapshot.fromJson(diskCached!.snapshot!);
        _snapshotCache[memoryKey] = snapshot;
        return snapshot;
      }
    }

    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) return inFlight;
    final future = () async {
      final snapshot = await _buildSnapshot(config, id);
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

  static Future<_WebDavComicSnapshot> _buildSnapshot(
    WebDavLibraryConfig config,
    String id,
  ) async {
    final comicPath = config.childDirectoryPath(id);
    final entries = List<WebDavLibraryEntry>.from(
      await ops.readDir(config, comicPath),
    );
    final rootImages = _imageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).toList();
    final directories =
        entries
            .where((entry) => entry.isDirectory)
            .where((entry) => !_isIgnoredEntry(entry.name))
            .toList()
          ..sort((a, b) => compareComicFileNames(a.name, b.name));
    final metadata = await _readMetadata(
      config,
      comicPath,
      entries,
      pageCount: rootImages.length,
    );

    final metadataChapters = <String, ComicChapter>{};
    final chapterMap = <String, String>{};
    if (metadata?.chapters?.isNotEmpty == true) {
      for (var index = 0; index < metadata!.chapters!.length; index++) {
        final chapter = metadata.chapters![index];
        final chapterId = '$_metadataChapterPrefix$index';
        metadataChapters[chapterId] = chapter;
        chapterMap[chapterId] = chapter.title;
      }
    } else {
      for (final directory in directories) {
        chapterMap[directory.name] = directory.name;
      }
      if (chapterMap.isEmpty && rootImages.isNotEmpty) {
        chapterMap[rootChapterId] = rootChapterTitle;
      }
    }
    if (chapterMap.isEmpty) {
      throw const FormatException(
        'No images found in the WebDAV comic directory',
      );
    }

    final namedCover = _findNamedCover(entries);
    String? coverPath = namedCover == null
        ? null
        : config.childFilePath(comicPath, namedCover.name);
    if (rootImages.isNotEmpty) {
      coverPath ??= config.childFilePath(comicPath, rootImages.first.name);
    }
    if (coverPath == null) {
      for (final directory in directories) {
        final chapterPath = config.childDirectoryPathFrom(
          comicPath,
          directory.name,
        );
        try {
          final chapterEntries = List<WebDavLibraryEntry>.from(
            await ops.readDir(config, chapterPath),
          );
          final chapterCover = _findNamedCover(chapterEntries);
          final chapterPages = _imageEntries(
            chapterEntries,
          ).where((entry) => !isNamedComicCover(entry.name)).toList();
          final coverEntry = chapterCover ?? chapterPages.firstOrNull;
          if (coverEntry != null) {
            coverPath = config.childFilePath(chapterPath, coverEntry.name);
            break;
          }
        } catch (e) {
          Log.warning(
            'WebDAV Library',
            'Failed to inspect chapter cover at $chapterPath: $e',
          );
        }
      }
    }

    final metadataTitle = metadata?.title.trim() ?? '';
    return _WebDavComicSnapshot(
      title: metadataTitle.isEmpty ? id : metadataTitle,
      author: metadata?.author ?? '',
      tags: metadata?.tags ?? const [],
      cover: coverPath ?? '',
      chapters: chapterMap,
      metadataChapters: metadataChapters,
      rootImages: rootImages,
    );
  }

  static Future<ComicMetaData?> _readMetadata(
    WebDavLibraryConfig config,
    String comicPath,
    List<WebDavLibraryEntry> entries, {
    required int pageCount,
  }) async {
    final metadataEntry = entries.firstWhereOrNull(
      (entry) =>
          !entry.isDirectory && entry.name.toLowerCase() == _metadataFileName,
    );
    if (metadataEntry == null) return null;

    final metadataPath = config.childFilePath(comicPath, metadataEntry.name);
    try {
      final decoded = jsonDecode(await ops.readText(config, metadataPath));
      if (decoded is! Map) {
        throw const FormatException('metadata.json must contain an object');
      }
      final metadata = ComicMetaData.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      metadata.validateChapterRanges(pageCount: pageCount);
      return metadata;
    } catch (e) {
      Log.warning(
        'WebDAV Library',
        'Ignoring invalid metadata at $metadataPath: $e',
      );
      return null;
    }
  }

  static Future<Map<String, dynamic>> getImageLoadingConfig(
    String imageKey,
    String comicId,
    String epId,
  ) async {
    final config = WebDavLibraryConfig.fromSettings();
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  static Map<String, dynamic> getThumbnailLoadingConfig(String imageKey) {
    final config = WebDavLibraryConfig.fromSettings();
    if (imageKey.startsWith('cover.')) {
      return {'headers': config.authHeaders};
    }
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  static List<WebDavLibraryEntry> _imageEntries(
    List<WebDavLibraryEntry> entries,
  ) {
    return sortedComicImageEntries(
      entries.where((entry) => !entry.isDirectory),
      nameOf: (entry) => entry.name,
    );
  }

  static WebDavLibraryEntry? _findNamedCover(List<WebDavLibraryEntry> entries) {
    return findNamedComicCover(
      _imageEntries(entries),
      nameOf: (entry) => entry.name,
    );
  }

  static bool _isIgnoredEntry(String name) {
    return isIgnoredComicStorageEntry(name) || isComicArchiveFileName(name);
  }
}

class _WebDavComicSnapshot {
  const _WebDavComicSnapshot({
    required this.title,
    required this.author,
    required this.tags,
    required this.cover,
    required this.chapters,
    required this.metadataChapters,
    required this.rootImages,
  });

  final String title;
  final String author;
  final List<String> tags;
  final String cover;
  final Map<String, String> chapters;
  final Map<String, ComicChapter> metadataChapters;
  final List<WebDavLibraryEntry> rootImages;

  factory _WebDavComicSnapshot.fromJson(Map<String, dynamic> json) {
    final chapters = json['chapters'];
    final metadataChapters = json['metadataChapters'];
    final rootImages = json['rootImages'];
    return _WebDavComicSnapshot(
      title: json['title'] as String,
      author: json['author'] as String? ?? '',
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      cover: json['cover'] as String? ?? '',
      chapters: chapters is Map
          ? chapters.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      metadataChapters: metadataChapters is Map
          ? metadataChapters.map(
              (key, value) => MapEntry(
                key.toString(),
                ComicChapter.fromJson(Map<String, dynamic>.from(value as Map)),
              ),
            )
          : const {},
      rootImages: rootImages is List
          ? rootImages
                .whereType<Map>()
                .map(
                  (entry) => WebDavLibraryEntry(
                    name: entry['name'] as String,
                    isDirectory: false,
                    eTag: entry['eTag'] as String?,
                    modifiedAt: entry['modifiedAt'] as int?,
                  ),
                )
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': webDavLibrarySnapshotFormatVersion,
    'title': title,
    'author': author,
    'tags': tags,
    'cover': cover,
    'chapters': chapters,
    'metadataChapters': metadataChapters.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'rootImages': [
      for (final entry in rootImages)
        {
          'name': entry.name,
          'eTag': entry.eTag,
          'modifiedAt': entry.modifiedAt,
        },
    ],
  };

  List<String> get listTags => <String>{'WebDAV', ...tags}.toList();

  Map<String, List<String>> get detailTags => {
    'Source': const ['WebDAV'],
    if (tags.isNotEmpty) 'Tags': tags,
  };
}
