import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"],
      subtitle = row["subtitle"],
      cover = row["cover"],
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String)
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  late String _dbPath;

  int get length => _db.select("select count(*) from history;").first[0] as int;

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

    _db.execute("""
        create table if not exists history  (
          id text primary key,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int
        );
      """);

    var columns = _db.select("PRAGMA table_info(history);");
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      _db.execute("alter table history add column chapter_group int;");
    }

    notifyListeners();
    ImageFavoriteManager().init();
    clearExpiredHistory(
      (appdata.settings['historyRetentionDays'] as num?)?.round() ?? 0,
    );
    isInitialized = true;
  }

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        db.execute(_insertHistorySql, [
          newItem.id,
          newItem.title,
          newItem.subtitle,
          newItem.cover,
          newItem.time.millisecondsSinceEpoch,
          newItem.type.value,
          newItem.ep,
          newItem.page,
          newItem.readEpisode.join(','),
          newItem.maxPage,
          newItem.group,
        ]);
      } finally {
        db.dispose();
      }
    });
  }

  Future<void> _asyncHistoryQueue = Future.value();

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) {
    return _enqueueAsyncHistoryWrite(newItem);
  }

  Future<void> _enqueueAsyncHistoryWrite(History newItem) {
    final next = _asyncHistoryQueue.then(
      (_) => _writeHistoryAsync(newItem),
      onError: (_) => _writeHistoryAsync(newItem),
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
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group,
    ]);
    _cacheHistory(newItem);
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void clearExpiredHistory(int retentionDays) {
    if (retentionDays <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    _db.execute(
      """
      delete from history
      where time < ?;
    """,
      [cutoff],
    );
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryIds = {};
    var res = _db.select("""
        select id from history;
      """);
    for (var element in res) {
      _cachedHistoryIds![element["id"] as String] = true;
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

    var res = _db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

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
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
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
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  static const _refreshConcurrency = 5;
  static const _refreshThrottleEvery = 5;

  @visibleForTesting
  static Future<void> debugRunThrottledRefreshTasks<T>(
    List<T> tasks, {
    int concurrency = _refreshConcurrency,
    int throttleEvery = _refreshThrottleEvery,
    Future<void> Function(Duration duration)? delay,
    required Future<void> Function(T task) run,
  }) {
    return _runThrottledRefreshTasks(
      tasks,
      concurrency: concurrency,
      throttleEvery: throttleEvery,
      delay: delay,
      run: run,
    );
  }

  static Future<void> _runThrottledRefreshTasks<T>(
    List<T> tasks, {
    required int concurrency,
    required int throttleEvery,
    Future<void> Function(Duration duration)? delay,
    required Future<void> Function(T task) run,
  }) async {
    if (tasks.isEmpty || concurrency <= 0) {
      return;
    }
    final wait = delay ?? _waitRefreshThrottle;
    var nextIndex = 0;
    var throttleGate = Future<void>.value();
    var schedulingLock = Future<void>.value();

    Future<T?> takeNext() {
      final previousSchedule = schedulingLock;
      final releaseSchedule = Completer<void>();
      schedulingLock = releaseSchedule.future;
      return () async {
        await previousSchedule;
        try {
          await throttleGate;
          if (nextIndex >= tasks.length) {
            return null;
          }
          final task = tasks[nextIndex];
          nextIndex++;
          if (throttleEvery > 0 && nextIndex % throttleEvery == 0) {
            throttleGate = wait(_refreshThrottleDelay(nextIndex));
          }
          return task;
        } finally {
          releaseSchedule.complete();
        }
      }();
    }

    Future<void> worker() async {
      while (true) {
        final task = await takeNext();
        if (task == null) {
          return;
        }
        await run(task);
      }
    }

    final workerCount = min(concurrency, tasks.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  static Future<void> _waitRefreshThrottle(Duration duration) {
    return Future.delayed(duration);
  }

  static Duration _refreshThrottleDelay(int scheduledCount) {
    var delay = scheduledCount % 100 + 1;
    if (delay > 10) {
      delay = 10;
    }
    return Duration(seconds: delay);
  }

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

    await _runThrottledRefreshTasks(
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
