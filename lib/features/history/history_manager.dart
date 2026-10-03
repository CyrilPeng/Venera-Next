import 'history_cache.dart';
import 'history_repository.dart';
import 'history_model.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/features/history/image_favorites.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';

typedef HistoryMetadataUpdater =
    Future<bool> Function({String? title, String? subtitle, String? cover});

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  Database get imageFavoritesDatabase => _db;

  late String _dbPath;

  HistoryRepository get _repository => HistoryRepository(_db);

  int get length => _repository.count();

  late final _historyCache = HistoryCache(
    identities: ({String? id}) => _repository.identities(id: id),
    load: (id, type) => _repository.find(id, type),
  );

  bool isInitialized = false;
  int _generation = 0;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    ++_generation;
    _dbPath = "${App.dataPath}/history.db";
    _db = openSqliteDatabase(_dbPath);

    _repository.initialize();

    notifyListeners();
    ImageFavoriteManager().init();
    isInitialized = true;
    await clearExpiredHistory(
      (appdata.settings['historyRetentionDays'] as num?)?.round() ?? 0,
    );
  }

  static Future<void> _addHistoryAsync(
    String dbPath,
    History newItem,
    bool replaceMetadata,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        final repository = HistoryRepository(db);
        if (replaceMetadata) {
          repository.importHistory(newItem);
        } else {
          repository.writeProgress(newItem);
        }
      } finally {
        db.dispose();
      }
    });
  }

  static Future<void> _addReadDurationAsync(
    String dbPath,
    History item,
    int durationMs,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        HistoryRepository(db).addReadDuration(item, durationMs);
      } finally {
        db.dispose();
      }
    });
  }

  Future<void> _asyncHistoryQueue = Future.value();
  int _pendingWrites = 0;

  bool get hasPendingWrites => _pendingWrites != 0;

  /// Submit a detached progress snapshot to the ordered mutation queue.
  Future<void> addHistory(History newItem) =>
      _writeHistory(newItem, replaceMetadata: false);

  Future<void> importHistory(History newItem) =>
      _writeHistory(newItem, replaceMetadata: true);

  /// Serialize a synchronous external commit with accepted history writes.
  /// The writer must finish its transaction before returning. Cache publication
  /// and completion callbacks run without yielding to later queued mutations.
  Future<void> importStorage(
    void Function(String databasePath) write, {
    required void Function() onCommitted,
  }) {
    if (!isInitialized) {
      return Future.error(StateError('History database is closed'));
    }
    final generation = _generation;
    final path = _dbPath;
    return _enqueueAsyncWrite(() async {
      if (!isInitialized || generation != _generation) {
        throw StateError('History import belongs to a closed connection');
      }
      write(path);
      _historyCache.refresh(invalidateRecords: true);
      onCommitted();
      notifyListeners();
    });
  }

  Future<void> _writeHistory(History newItem, {required bool replaceMetadata}) {
    final snapshot = newItem.copy();
    final path = _dbPath;
    final generation = _generation;
    return _enqueueAsyncWrite(() async {
      await _addHistoryAsync(path, snapshot, replaceMetadata);
      if (isInitialized && generation == _generation) {
        _cachePersistedHistory(snapshot.id, snapshot.type.value);
        notifyListeners();
      }
    });
  }

  Future<T> _enqueueAsyncWrite<T>(Future<T> Function() write) {
    _pendingWrites++;
    final next = _asyncHistoryQueue.then((_) => write()).whenComplete(() {
      _pendingWrites--;
    });
    _asyncHistoryQueue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        Log.error("History", error, stackTrace);
      },
    );
    return next;
  }

  void _cachePersistedHistory(String id, int type) {
    final stored = _repository.find(id, type);
    if (stored == null) {
      updateCache();
    } else {
      _cacheHistory(stored);
    }
  }

  /// Atomically adds foreground reading time without replacing progress data.
  Future<void> addReadDuration(History item, Duration duration) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return Future.value();
    final snapshot = item.copy();
    final path = _dbPath;
    final generation = _generation;
    return _enqueueAsyncWrite(() async {
      await _addReadDurationAsync(path, snapshot, durationMs);
      if (item.id == snapshot.id && item.type == snapshot.type) {
        item.readDurationMs += durationMs;
      }
      if (isInitialized && generation == _generation) {
        _cachePersistedHistory(snapshot.id, snapshot.type.value);
        notifyListeners();
      }
    });
  }

  Future<void> waitForAsyncWrites() async {
    do {
      final accepted = _asyncHistoryQueue;
      await accepted;
      if (identical(accepted, _asyncHistoryQueue)) return;
    } while (true);
  }

  /// Capture this before starting a metadata request. Late responses cannot
  /// target a reopened database or follow mutation of the caller's identity.
  HistoryMetadataUpdater metadataUpdaterFor(History item) {
    final id = item.id;
    final type = item.type.value;
    final generation = _generation;
    final path = isInitialized ? _dbPath : null;
    return ({String? title, String? subtitle, String? cover}) {
      if (path == null || !isInitialized || generation != _generation) {
        return Future.value(false);
      }
      return _enqueueAsyncWrite(() async {
        final changed = await _updateMetadataAsync(
          path,
          id,
          type,
          title: title,
          subtitle: subtitle,
          cover: cover,
        );
        if (changed && isInitialized && generation == _generation) {
          _cachePersistedHistory(id, type);
          notifyListeners();
        }
        return changed;
      });
    };
  }

  static Future<bool> _updateMetadataAsync(
    String path,
    String id,
    int type, {
    String? title,
    String? subtitle,
    String? cover,
  }) => Isolate.run(() {
    final db = openSqliteDatabase(path);
    try {
      return HistoryRepository(db).updateMetadata(
        id,
        type,
        title: title,
        subtitle: subtitle,
        cover: cover,
      );
    } finally {
      db.dispose();
    }
  });

  void _cacheHistory(History item) => _historyCache.record(item);

  static Future<void> _mutateDatabase(
    String path,
    void Function(HistoryRepository) mutate,
  ) => Isolate.run(() {
    final db = openSqliteDatabase(path);
    try {
      mutate(HistoryRepository(db));
    } finally {
      db.dispose();
    }
  });

  Future<void> _delete(void Function(HistoryRepository) mutate) {
    final path = _dbPath;
    final generation = _generation;
    return _enqueueAsyncWrite(() async {
      await _mutateDatabase(path, mutate);
      if (isInitialized && generation == _generation) {
        updateCache();
        notifyListeners();
      }
    });
  }

  Future<void> clearHistory() => _delete((repository) => repository.clear());

  Future<void> clearExpiredHistory(int retentionDays) {
    if (retentionDays <= 0) return Future.value();
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    return _delete((repository) => repository.clearBefore(cutoff));
  }

  Future<void> clearUnfavoritedHistory() {
    // The user's deletion decision uses the favorite identities at submission.
    // Do not read a potentially closed/reopened favorites manager in an isolate.
    final favorites = LocalFavoritesManager()
        .getAllComics()
        .map((item) => (item.id, item.type.value))
        .toSet();
    return _delete(
      (repository) =>
          repository.deleteWhere((id, type) => !favorites.contains((id, type))),
    );
  }

  Future<void> remove(String id, ComicType type) {
    final value = type.value;
    return _delete((repository) => repository.remove(id, value));
  }

  void updateCache() => _historyCache.refresh();

  History? find(String id, ComicType type) =>
      _historyCache.find(id, type.value);

  List<History> getAll() => _repository.getAll();
  List<History> getRecent() => _repository.getRecent();
  int count() => _repository.count();
  int getTotalReadDurationMs() => _repository.getTotalReadDurationMs();
  int countWithReadDuration() => _repository.countWithReadDuration();
  List<History> getAllByReadDuration() => _repository.getAllByReadDuration();

  void close() {
    ++_generation;
    isInitialized = false;
    _historyCache.clear();
    _db.dispose();
  }

  void notifyChanges() {
    _historyCache.refresh(invalidateRecords: true);
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(
    History history, {
    Future<void> Function(Duration duration)? retryDelay,
  }) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history, retryDelay: retryDelay);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(
    History history, {
    Future<void> Function(Duration duration)? retryDelay,
  }) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    final id = history.id;
    final updateMetadata = metadataUpdaterFor(history);
    final waitRetry = retryDelay ?? Future<void>.delayed;
    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(id);
        if (res.error) {
          retries--;
          if (retries == 0) {
            return false;
          }
          await waitRetry(const Duration(seconds: 2));
          continue;
        }

        var comicDetails = res.data;
        return await updateMetadata(
          title: comicDetails.title,
          subtitle: comicDetails.subTitle ?? '',
          cover: comicDetails.cover,
        );
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        retries--;
        if (retries == 0) {
          return false;
        }
        await waitRetry(const Duration(seconds: 2));
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  static const _refreshConcurrency = 5;
  static const _refreshThrottleEvery = 5;

  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var cancelled = false;
    final controller = StreamController<RefreshProgress>(
      onCancel: () {
        cancelled = true;
      },
    );
    _refreshAllHistoriesBase(controller, () => cancelled);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
    bool Function() isCancelled,
  ) async {
    try {
      var histories = getAll();
      int total = histories.length;
      int current = 0;
      int success = 0;
      int failed = 0;
      int skipped = 0;

      controller.add(RefreshProgress(total, current, success, failed, skipped));

      var historiesToRefresh = <History>[];
      for (var history in histories) {
        if (history.sourceKey == 'local') {
          skipped++;
          current++;
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
          continue;
        }
        historiesToRefresh.add(history);
      }

      total = historiesToRefresh.length;
      current = 0;
      controller.add(RefreshProgress(total, current, success, failed, skipped));

      await runThrottledTasks(
        historiesToRefresh,
        concurrency: _refreshConcurrency,
        throttleEvery: _refreshThrottleEvery,
        isCancelled: isCancelled,
        run: (history) async {
          if (isCancelled()) return;
          var result = await _refreshSingleHistory(history);
          if (isCancelled()) return;
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        },
      );

      if (!isCancelled()) notifyListeners();
    } catch (error, stack) {
      if (!isCancelled()) controller.addError(error, stack);
    } finally {
      await controller.close();
    }
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
