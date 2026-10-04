import 'dart:async';
import 'dart:convert';
import 'webdav_library_cache.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_snapshot.dart';
import 'webdav_library_snapshot_builder.dart';

class WebDavLibrarySnapshotStore {
  WebDavLibrarySnapshotStore(this._cache);

  final WebDavLibraryCache _cache;
  final _snapshotCache = <String, WebDavComicSnapshot>{};
  final _snapshotInFlight = <String, Future<WebDavComicSnapshot>>{};
  final _ownedBuilds = <_SnapshotBuild>{};
  int _generation = 0;
  bool _closed = false;
  bool _exitHeld = false;
  int _exitGeneration = 0;
  Future<void>? _closing;
  Future<void Function()>? _exitPreparation;

  /// Invalidate reusable results without losing ownership of older builds.
  void clear() {
    _generation++;
    _snapshotCache.clear();
    _snapshotInFlight.clear();
  }

  /// Permanently reject loads, then join every accepted build and its commit.
  /// The source owns the disk cache and may close it after this completes.
  Future<void> closeAndWait() {
    final existing = _closing;
    if (existing != null) return existing;
    _closed = true;
    _exitHeld = true;
    _exitGeneration++;
    clear();
    return _closing = _drainBuilds();
  }

  /// Reject new loads until release and prevent accepted builds from publishing
  /// stale snapshots while the host prepares other owners for shutdown.
  Future<void Function()> prepareForExit() {
    if (_closed) {
      return Future.error(StateError('WebDAV snapshot store is closed'));
    }
    final existing = _exitPreparation;
    if (existing != null) return existing;
    _exitHeld = true;
    final generation = ++_exitGeneration;
    clear();
    void release() {
      if (_closed || !_exitHeld || generation != _exitGeneration) return;
      _exitHeld = false;
      _exitPreparation = null;
    }

    return _exitPreparation = _prepareForExit(release);
  }

  Future<void Function()> _prepareForExit(void Function() release) async {
    try {
      await _drainBuilds();
      return release;
    } catch (_) {
      release();
      rethrow;
    }
  }

  Future<void> _drainBuilds() async {
    while (_ownedBuilds.isNotEmpty) {
      // Work errors belong to load callers. Settled only completes after each
      // build's finally, including builds removed from the deduplication map.
      await Future.wait(_ownedBuilds.map((build) => build.settled.future));
    }
  }

  void _checkGeneration(WebDavLibrarySession session, int generation) {
    if (_closed || _exitHeld || generation != _generation) {
      throw const WebDavLibraryCancelled();
    }
    session.check();
  }

  Future<WebDavComicSnapshot> load(
    WebDavLibrarySession session,
    String id, {
    bool forceRefresh = false,
    WebDavLibraryRemoteDirectory? remoteDirectory,
    List<WebDavLibraryEntry>? rootEntries,
  }) async {
    if (_closed) throw StateError('WebDAV snapshot store is closed');
    if (_exitHeld) {
      throw StateError('WebDAV snapshot store is preparing to exit');
    }
    final generation = _generation;
    session.check();
    final config = session.config;
    final memoryKey = jsonEncode([config.cacheKey, id]);
    if (!forceRefresh) {
      final memoryCached = _snapshotCache[memoryKey];
      if (memoryCached != null) return memoryCached;
      final diskCached = _cache.find(config.cacheKey, id);
      if (diskCached?.isReady == true) {
        final snapshot = WebDavComicSnapshot.fromJson(diskCached!.snapshot!);
        _checkGeneration(session, generation);
        _snapshotCache[memoryKey] = snapshot;
        return snapshot;
      }
    }

    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) return inFlight;
    _checkGeneration(session, generation);
    final build = _SnapshotBuild();
    _ownedBuilds.add(build);
    _snapshotInFlight[memoryKey] = build.result.future;
    unawaited(
      _build(
        build,
        session,
        id,
        memoryKey,
        generation,
        remoteDirectory: remoteDirectory,
        rootEntries: rootEntries,
      ),
    );
    return build.result.future;
  }

  Future<void> _build(
    _SnapshotBuild build,
    WebDavLibrarySession session,
    String id,
    String memoryKey,
    int generation, {
    WebDavLibraryRemoteDirectory? remoteDirectory,
    List<WebDavLibraryEntry>? rootEntries,
  }) async {
    final config = session.config;
    try {
      final snapshot = await WebDavLibrarySnapshotBuilder(
        session,
      ).build(id, rootEntries: rootEntries);
      _checkGeneration(session, generation);
      final existing = _cache.find(config.cacheKey, id);
      _checkGeneration(session, generation);
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
      _checkGeneration(session, generation);
      _snapshotCache[memoryKey] = snapshot;
      build.result.complete(snapshot);
    } catch (error, stack) {
      build.result.completeError(error, stack);
    } finally {
      if (identical(_snapshotInFlight[memoryKey], build.result.future)) {
        _snapshotInFlight.remove(memoryKey);
      }
      _ownedBuilds.remove(build);
      build.settled.complete();
    }
  }
}

class _SnapshotBuild {
  final result = Completer<WebDavComicSnapshot>();
  final settled = Completer<void>();
}
