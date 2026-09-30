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

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
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
    return _enqueueAsyncWrite(() => _writeHistoryAsync(newItem));
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

  Future<void> _writeHistoryAsync(History newItem) async {
    await _addHistoryAsync(_dbPath, newItem);
    _cacheHistory(newItem);
    notifyListeners();
  }

  /// Atomically adds foreground reading time without replacing progress data.
  Future<void> addReadDuration(History item, Duration duration) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return Future.value();
    return _enqueueAsyncWrite(() async {
      await _addReadDurationAsync(_dbPath, item, durationMs);
      item.readDurationMs += durationMs;
      _cacheHistory(item);
      notifyListeners();
    });
  }

  Future<void> waitForAsyncWrites() {
    return _asyncHistoryQueue;
  }

  void _cacheHistory(History newItem) {
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![newItem.id] = true;
    }
    cachedHistories[newItem.id] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
  }

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

  void updateCache() {
    _cachedHistoryIds = {};
    for (final id in _repository.ids()) {
      _cachedHistoryIds![id] = true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    if (!_cachedHistoryIds!.containsKey(id)) {
      return null;
    }
    if (cachedHistories.containsKey(id)) {
      return cachedHistories[id];
    }

    return _repository.find(id, type.value);
  }

  List<History> getAll() => _repository.getAll();
  List<History> getRecent() => _repository.getRecent();
  int count() => _repository.count();
  int getTotalReadDurationMs() => _repository.getTotalReadDurationMs();
  int countWithReadDuration() => _repository.countWithReadDuration();
  List<History> getAllByReadDuration() => _repository.getAllByReadDuration();

  void close() {
    isInitialized = false;
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
