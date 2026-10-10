import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_storage/comic_storage.dart';
import 'package:venera_next/features/webdav_library/webdav_library_cache.dart';
import 'package:venera_next/features/webdav_library/webdav_library_config.dart';
import 'package:venera_next/features/webdav_library/webdav_library_settings.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';

import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_transport.dart';
import 'webdav_library_snapshot_store.dart';
import 'webdav_library_synchronizer.dart';

class WebDavLibraryLifecycleFailure implements Exception {
  WebDavLibraryLifecycleFailure(
    Iterable<({String operation, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String operation, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'WebDAV library cleanup failed: '
      '${failures.map((failure) => '${failure.operation}: ${failure.error}').join('; ')}';
}

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
  int _generation = 0;
  final _pending = <Future<void>>{};
  Future<void>? _closing;
  Future<void Function()>? _exitPreparation;
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
    _checkAvailable();
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
          _exitPreparation == null &&
          _readSettings().connection.connectionKey == config.connectionKey,
    );
  }

  void _checkAvailable() {
    if (_disposed) throw StateError('WebDAV library is disposed');
    if (_exitPreparation != null) {
      throw StateError('WebDAV library is preparing to exit');
    }
  }

  Future<T> _own<T>(Future<T> Function() work) {
    final settled = Completer<void>();
    _pending.add(settled.future);
    return Future<T>.sync(work).whenComplete(() {
      _pending.remove(settled.future);
      settled.complete();
    });
  }

  Future<void> _drainCalls() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  void _cancelSession() {
    _generation++;
    _session?.cancel();
    _session = null;
  }

  /// Freeze immediately; cache and notifications stay alive until all owned
  /// work finishes. Use closeAndWait when shutdown failures must be observed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelSession();
    final ready = Completer<void>();
    _closing = ready.future;
    final failures = <({String operation, Object error, StackTrace stack})>[];
    final waits = [
      _attempt('synchronizer', synchronizer.closeAndWait, failures),
      _attempt('snapshots', _snapshots.closeAndWait, failures),
      _attempt('transport cancellation', _ops.cancelPending, failures),
      _attempt('transport', _ops.dispose, failures),
      _drainCalls(),
    ];
    _finishClose(
      waits,
      failures,
    ).then((_) => ready.complete(), onError: ready.completeError);
    _closing!.catchError((Object error, StackTrace stack) {
      Log.error('WebDAV Library shutdown', error, stack);
    }).ignore();
  }

  Future<void> closeAndWait() {
    dispose();
    return _closing!;
  }

  Future<void> _finishClose(
    List<Future<void>> waits,
    List<({String operation, Object error, StackTrace stack})> failures,
  ) async {
    await Future.wait(waits);
    await _attempt('transport completion', _ops.drainPending, failures);
    await _attempt('cache', _cache.dispose, failures);
    await _attempt('content notifications', contentVersion.dispose, failures);
    if (failures.isNotEmpty) throw WebDavLibraryLifecycleFailure(failures);
  }

  /// Temporarily stop admissions and cancel active requests while retaining
  /// storage and clients for a cancelled window close.
  Future<void Function()> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('WebDAV library is disposed'));
    }
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final ready = Completer<void Function()>();
    final preparation = _exitPreparation = ready.future;
    _cancelSession();
    final releases = <void Function()>[];
    final failures = <({String operation, Object error, StackTrace stack})>[];
    void release() {
      if (!identical(_exitPreparation, preparation)) return;
      for (final release in releases.reversed) {
        release();
      }
      _exitPreparation = null;
    }

    final waits = [
      _attempt('synchronizer', () async {
        releases.add(await synchronizer.prepareForExit());
      }, failures),
      _attempt('snapshots', () async {
        releases.add(await _snapshots.prepareForExit());
      }, failures),
      _attempt('transport cancellation', _ops.cancelPending, failures),
      _drainCalls(),
    ];
    Future.wait(waits).then((_) async {
      await _attempt('transport completion', _ops.drainPending, failures);
      if (failures.isEmpty) {
        ready.complete(release);
      } else {
        release();
        ready.completeError(WebDavLibraryLifecycleFailure(failures));
      }
    });
    return preparation;
  }

  Future<void> _attempt(
    String operation,
    FutureOr<void> Function() cleanup,
    List<({String operation, Object error, StackTrace stack})> failures,
  ) async {
    try {
      await cleanup();
    } catch (error, stack) {
      failures.add((operation: operation, error: error, stack: stack));
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

  Future<Res<bool>> testConnection(WebDavLibraryConfig config) =>
      _own(() async {
        if (!config.isValid) {
          return const Res.error('Invalid WebDAV comic library configuration');
        }
        try {
          _checkAvailable();
          final generation = _generation;
          await _ops.test(config);
          _checkAvailable();
          if (generation != _generation) throw const WebDavLibraryCancelled();
          return const Res(true);
        } catch (e, stack) {
          return Res.fromException(e, stack);
        }
      });

  Future<Res<List<Comic>>> loadComics(int page) => _own(() async {
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return const Res.error('Invalid WebDAV comic library configuration');
    }
    try {
      if (page < 1) return const Res([], subData: 1);
      final indexResult = await synchronizer.ensureIndex(session);
      if (indexResult.error) {
        return Res.fromErrorRes(indexResult);
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
    } catch (e, stack) {
      return Res.fromException(e, stack);
    }
  });

  Future<Res<ComicDetails>> loadComicInfo(String id) => _own(() async {
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
    } catch (e, stack) {
      return Res.fromException(e, stack);
    }
  });

  Future<Res<List<String>>> loadComicPages(String id, String? ep) =>
      _own(() async {
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
          final metadataChapter = ep == null
              ? null
              : snapshot.metadataChapters[ep];
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
        } catch (e, stack) {
          return Res.fromException(e, stack);
        }
      });

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
