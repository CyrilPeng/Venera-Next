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
    clearExpiredHistory(
      (appdata.settings['historyRetentionDays'] as num?)?.round() ?? 0,
    );
    isInitialized = true;
  }

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        HistoryRepository(db).writeProgress(newItem);
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

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) {
    final snapshot = newItem.copy();
    final path = _dbPath;
    final generation = _generation;
    return _enqueueAsyncWrite(() async {
      await _addHistoryAsync(path, snapshot);
      if (isInitialized && generation == _generation) {
        _cachePersistedHistory(snapshot);
        notifyListeners();
      }
    });
  }

  Future<void> _enqueueAsyncWrite(Future<void> Function() write) {
    final next = _asyncHistoryQueue.then(
      (_) => write(),
      onError: (_) => write(),
    );
    _asyncHistoryQueue = next.catchError((Object error, StackTrace stackTrace) {
      Log.error("History", error, stackTrace);
    });
    return next;
  }

  void _cachePersistedHistory(History snapshot) {
    final stored = _repository.find(snapshot.id, snapshot.type.value);
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
        _cachePersistedHistory(snapshot);
        notifyListeners();
      }
    });
  }

  Future<void> waitForAsyncWrites() {
    return _asyncHistoryQueue;
  }

  void _cacheHistory(History item) => _historyCache.record(item);

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _repository.writeProgress(newItem);
    _cacheHistory(newItem);
    notifyListeners();
  }

  void clearHistory() {
    _repository.clear();
    updateCache();
    notifyListeners();
  }

  void clearExpiredHistory(int retentionDays) {
    if (retentionDays <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    _repository.clearBefore(cutoff);
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _repository.deleteWhere(
      (id, type) => !LocalFavoritesManager().isExist(id, ComicType(type)),
    );
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    _repository.remove(id, type.value);
    updateCache();
    notifyListeners();
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
    updateCache();
    notifyListeners();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _repository.removeMany(
      histories.map((history) => (history.id, history.type.value)),
    );
    updateCache();
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

    final waitRetry = retryDelay ?? Future<void>.delayed;
    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          retries--;
          if (retries == 0) {
            return false;
          }
          await waitRetry(const Duration(seconds: 2));
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
          'read_duration_ms': history.readDurationMs,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
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
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
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
      run: (history) async {
        var result = await _refreshSingleHistory(history);
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

    notifyListeners();
    controller.close();
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
