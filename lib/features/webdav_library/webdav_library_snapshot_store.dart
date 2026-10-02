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

  void clear() {
    _snapshotCache.clear();
    _snapshotInFlight.clear();
  }

  Future<WebDavComicSnapshot> load(
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
}
