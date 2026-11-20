import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'history_manager.dart';
import 'image_favorite_actions.dart';
import 'image_favorites_models.dart';
import 'image_favorites_cache.dart';
import 'image_favorites_statistics.dart';

class ImageFavoriteManager with ChangeNotifier {
  ImageFavoriteManager.create({
    required HistoryManager history,
    Future<void> Function(ImageFavorite)? deleteCache,
    Future<ImageFavoritesComputed> Function(String)? readStatistics,
  }) : _history = (() => history),
       _deleteCache = deleteCache ?? deleteImageFavoriteCache,
       _readStatistics = readStatistics ?? readImageFavoritesStatistics;

  ImageFavoriteManager._()
    : _history = HistoryManager.new,
      _deleteCache = deleteImageFavoriteCache,
      _readStatistics = readImageFavoritesStatistics;

  static ImageFavoriteManager? _cache;
  factory ImageFavoriteManager() => (_cache ??= ImageFavoriteManager._());
  final HistoryManager Function() _history;
  final Future<void> Function(ImageFavorite) _deleteCache;
  final Future<ImageFavoritesComputed> Function(String) _readStatistics;

  // Bound status caching to one chapter. Reads still use ordered admission,
  // including cache hits, so imports and connection retirement keep priority.
  Object? _chapterKey;
  Set<int> _chapterPages = const {};
  Database? _observedDatabase;
  StreamSubscription<SqliteUpdate>? _databaseChanges;
  bool _disposed = false;

  void _invalidateChapter() {
    _chapterKey = null;
    _chapterPages = const {};
  }

  void _observeDatabase(Database database) {
    if (_disposed || identical(database, _observedDatabase)) return;
    _invalidateChapter();
    unawaited(_databaseChanges?.cancel());
    _observedDatabase = database;
    _databaseChanges = database.updatesSync.listen(
      (update) {
        // SQLite invokes this during a write. Only invalidate here: querying
        // or publishing would let observers reenter an unfinished transaction.
        if (identical(database, _observedDatabase) &&
            update.tableName == 'image_favorites') {
          _invalidateChapter();
        }
      },
      onDone: () {
        if (identical(database, _observedDatabase)) {
          _observedDatabase = null;
          _databaseChanges = null;
          _invalidateChapter();
        }
      },
    );
  }

  /// Capture before an asynchronous selection; it cannot move to a reopened
  /// database or another application instance while the user chooses an image.
  ImageFavoriteAccess capture() => ImageFavoriteAccess._(this, _history());

  @override
  void notifyListeners() {
    // Whole-store imports and truncating DELETEs need explicit invalidation;
    // SQLite's row update hook does not report every replacement operation.
    _invalidateChapter();
    _history().publishChange(super.notifyListeners);
  }

  Future<List<ImageFavoritesComic>> getAll([String? keyword]) => _history()
      .accessImageFavorites((repository, _) => repository.getAll(keyword));

  Future<ImageFavoritesComic?> find(String id, String sourceKey) => _history()
      .accessImageFavorites((repository, _) => repository.find(id, sourceKey));

  Future<bool> isCollected(String id, String sourceKey, String eid, int page) =>
      _isCollected(_history(), id, sourceKey, eid, page);

  Future<bool> _isCollected(
    HistoryManager history,
    String id,
    String sourceKey,
    String eid,
    int page, {
    void Function()? checkActive,
  }) => history.accessImageFavorites((repository, _) {
    checkActive?.call();
    _observeDatabase(repository.db);
    final key = (history, history.connectionGeneration, id, sourceKey, eid);
    if (_chapterKey == key) return _chapterPages.contains(page);
    final pages = <int>{
      for (final image
          in repository.find(id, sourceKey)?.images ?? const <ImageFavorite>[])
        if (image.eid == eid) image.page,
    };
    // A failed query never installs a cache entry; the next read can retry.
    if (!_disposed) {
      _chapterKey = key;
      _chapterPages = pages;
    }
    return pages.contains(page);
  });

  /// Capture the intent now; read and mutate current data only after admission.
  Future<ImageFavoriteResult> toggle(
    ImageFavoriteInput input, {
    void Function()? checkActive,
  }) => _toggle(_history(), input, checkActive: checkActive);

  Future<ImageFavoriteResult> _toggle(
    HistoryManager history,
    ImageFavoriteInput input, {
    void Function()? checkActive,
  }) {
    final snapshot = input.detached();
    return history.accessImageFavorites((repository, _) async {
      checkActive?.call();
      _invalidateChapter();
      final removed = <ImageFavorite>[];
      var changed = false;
      final result = ImageFavoriteActions(
        findComic: repository.find,
        save: (comic) {
          repository.save(comic);
          changed = true;
        },
        remove: (image) {
          repository.removeImages([image]);
          removed.add(image);
          changed = true;
        },
      ).toggle(snapshot);
      if (changed) await _finishCommit(history, removed);
      return result;
    });
  }

  Future<void> deleteImageFavorite(Iterable<ImageFavorite> selected) {
    final images = selected.map((image) => image.copyWith()).toList();
    if (images.isEmpty) return Future.value();
    final history = _history();
    return history.accessImageFavorites((repository, _) async {
      _invalidateChapter();
      repository.removeImages(images);
      await _finishCommit(history, images);
    });
  }

  Future<void> _finishCommit(
    HistoryManager history,
    List<ImageFavorite> removed,
  ) async {
    final failures = <({Object error, StackTrace stackTrace})>[];
    // Start all cache removals before yielding; each captures its original path.
    await Future.wait(
      removed.map((image) async {
        try {
          await _deleteCache(image);
        } catch (error, stack) {
          failures.add((error: error, stackTrace: stack));
        }
      }),
    );
    try {
      history.publishChange(super.notifyListeners);
    } catch (error, stack) {
      failures.add((error: error, stackTrace: stack));
    }
    if (failures.isNotEmpty) {
      final first = failures.first;
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.committed,
          cause: first.error,
          stackTrace: first.stackTrace,
          cleanupFailures: failures.skip(1).toList(),
        ),
        first.stackTrace,
      );
    }
  }

  void notifyChanges() => notifyListeners();

  @override
  void dispose() {
    _disposed = true;
    _invalidateChapter();
    _observedDatabase = null;
    unawaited(_databaseChanges?.cancel());
    _databaseChanges = null;
    super.dispose();
  }

  Future<ImageFavoritesComputed> compute() =>
      _history().accessImageFavorites((repository, path) {
        if (repository.count() > 100) return _readStatistics(path);
        return computeImageFavorites(repository.getAll());
      });
}

class ImageFavoriteAccess {
  ImageFavoriteAccess._(this._manager, this._history)
    : _generation = _history.connectionGeneration;
  final ImageFavoriteManager _manager;
  final HistoryManager _history;
  final int _generation;
  Object get identity => (_history, _generation);
  bool get isCurrent =>
      identical(_manager._history(), _history) &&
      _history.isInitialized &&
      _history.connectionGeneration == _generation;

  void _check() {
    if (!isCurrent) {
      throw StateError('Image favorites belong to a retired database');
    }
  }

  Future<bool> isCollected(String id, String sourceKey, String eid, int page) =>
      _manager._isCollected(
        _history,
        id,
        sourceKey,
        eid,
        page,
        checkActive: _check,
      );

  Future<ImageFavoriteResult> toggle(
    ImageFavoriteInput input, {
    required void Function() checkActive,
  }) => _manager._toggle(
    _history,
    input,
    checkActive: () {
      checkActive();
      _check();
    },
  );
}
