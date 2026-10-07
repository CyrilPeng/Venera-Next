import 'history_cache.dart';
import 'history_repository.dart';
import 'history_model.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'image_favorites_repository.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';

typedef HistoryMetadataUpdater =
    Future<bool> Function({String? title, String? subtitle, String? cover});

/// Persists one increment on its owned connection. Failures carry an explicit
/// commit state; an unclassified failure is treated as an unknown outcome.
typedef HistoryDurationStorageWriter =
    Future<void> Function(
      String databasePath,
      History snapshot,
      int durationMs,
    );

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create({
    HistoryDurationStorageWriter? writeDuration,
    AppDataOperations? operations,
  }) : _writeDuration = writeDuration ?? _addReadDurationAsync,
       _operations = operations ?? AppDataOperations.instance;

  final HistoryDurationStorageWriter _writeDuration;
  final AppDataOperations _operations;

  @override
  void notifyListeners() => _operations.publish(super.notifyListeners);

  /// Image favorites share this database lifetime and ordered access queue.
  /// The callback may own a background reader, and must await its actual close.
  Future<T> accessImageFavorites<T>(
    FutureOr<T> Function(ImageFavoritesRepository repository, String path)
    action,
  ) => _enqueueAsyncWrite(() {
    if (!isInitialized) throw StateError('History database is closed');
    final path = _dbPath;
    final generation = _generation;
    return () async {
      if (!isInitialized || generation != _generation) {
        throw StateError('Image favorites belong to a closed connection');
      }
      return action(ImageFavoritesRepository(_db), path);
    };
  });

  /// Notifications from either table must not lend data access to listeners.
  void publishChange(void Function() notify) => _operations.publish(notify);

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  Database? _database;
  Database get _db =>
      _database ?? (throw StateError('History database is closed'));

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
  int get connectionGeneration => _generation;

  _HistoryInitialization? _initialization;

  Future<void> init() {
    if (_initialization == null && isInitialized) return Future.value();
    final attempt = _initialization ??= _HistoryInitialization(++_generation);
    // Every caller offers its own admission, while sharing one initialization.
    // An exclusive importer can start a pending attempt itself instead of
    // awaiting the external caller queued behind that same importer.
    _operations
        .access(() => attempt.work ??= _initialize(attempt.generation))
        .then(
          (_) {
            if (identical(_initialization, attempt)) {
              _initialization = null;
            }
            if (!attempt.result.isCompleted) attempt.result.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (identical(_initialization, attempt)) {
              _initialization = null;
            }
            if (!attempt.result.isCompleted) {
              attempt.result.completeError(error, stack);
            }
          },
        );
    return attempt.result.future;
  }

  void _checkInitialization(int generation) {
    if (generation != _generation || _database == null) {
      throw StateError('History initialization was closed');
    }
  }

  Future<void> _initialize(int generation) async {
    Database? database;
    try {
      if (generation != _generation) {
        throw StateError('History initialization was closed before admission');
      }
      _dbPath = "${App.dataPath}/history.db";
      database = openSqliteDatabase(_dbPath);
      _database = database;
      HistoryRepository(database).initialize();
      ImageFavoritesRepository(database).initialize();
      // Retention uses the ordered mutation queue. Even when disabled, drain
      // previously accepted writes before declaring this connection ready.
      await clearExpiredHistory(
        (appdata.settings['historyRetentionDays'] as num?)?.round() ?? 0,
      );
      _checkInitialization(generation);
      if (hasPendingWrites) await waitForAsyncWrites();
      _checkInitialization(generation);
      isInitialized = true;
      notifyListeners();
      _checkInitialization(generation);
    } catch (_) {
      // Closing an old attempt must never dispose a replacement connection.
      if (identical(_database, database) && generation == _generation) {
        isInitialized = false;
        _historyCache.clear();
        _database = null;
        database?.dispose();
      }
      rethrow;
    }
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
  ) async {
    try {
      await Isolate.run(() {
        Database? db;
        PersistenceFailure? failure;
        var committed = false;
        try {
          db = openSqliteDatabase(dbPath);
          // This repository call owns a complete transaction on this fresh
          // connection. A rollback failure leaves its commit state uncertain.
          HistoryRepository(db).addReadDuration(item, durationMs);
          committed = true;
        } catch (error, stack) {
          failure = PersistenceFailure(
            commitState: error is SqliteTransactionRollbackError
                ? PersistenceCommitState.unknown
                : PersistenceCommitState.notCommitted,
            cause: error,
            stackTrace: stack,
          );
        } finally {
          try {
            db?.dispose();
          } catch (error, stack) {
            final original = failure;
            failure = PersistenceFailure(
              commitState:
                  original?.commitState ??
                  (committed
                      ? PersistenceCommitState.committed
                      : PersistenceCommitState.notCommitted),
              cause: original?.cause ?? error,
              stackTrace: original?.stackTrace ?? stack,
              cleanupFailures: original == null
                  ? const []
                  : [
                      ...original.cleanupFailures,
                      (error: error, stackTrace: stack),
                    ],
            );
          }
        }
        if (failure != null) {
          Error.throwWithStackTrace(failure, failure.stackTrace);
        }
      });
    } on PersistenceFailure {
      rethrow;
    } catch (error, stack) {
      // Losing the worker/result channel does not prove that SQL rolled back.
      throw PersistenceFailure(
        commitState: PersistenceCommitState.unknown,
        cause: error,
        stackTrace: stack,
      );
    }
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
    return _enqueueAsyncWrite(() {
      if (!isInitialized) {
        throw StateError('History database is closed');
      }
      final generation = _generation;
      final path = _dbPath;
      return () async {
        if (!isInitialized || generation != _generation) {
          throw StateError('History import belongs to a closed connection');
        }
        write(path);
        _historyCache.refresh(invalidateRecords: true);
        _operations.publish(onCommitted);
        notifyListeners();
      };
    });
  }

  Future<void> _writeHistory(History newItem, {required bool replaceMetadata}) {
    final snapshot = newItem.copy();
    return _enqueueAsyncWrite(() {
      if (_database == null) throw StateError('History database is closed');
      final path = _dbPath;
      final generation = _generation;
      return () async {
        await _addHistoryAsync(path, snapshot, replaceMetadata);
        if (isInitialized && generation == _generation) {
          _cachePersistedHistory(snapshot.id, snapshot.type.value);
          notifyListeners();
        }
      };
    });
  }

  Future<T> _enqueueAsyncWrite<T>(Future<T> Function() Function() prepare) {
    _pendingWrites++;
    // Acquire before appending to the local queue. An import already holding
    // exclusive access must not wait for writes queued behind that import.
    return _operations
        .access(() {
          // Capture connection ownership at global admission, before waiting
          // for older local writes. Direct close/reopen cannot retarget work
          // already accepted; a replacement queued earlier is allowed to finish.
          final write = prepare();
          final next = _asyncHistoryQueue.then((_) => write());
          _asyncHistoryQueue = next.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              try {
                Log.error("History", error, stackTrace);
              } catch (_) {
                // The caller still receives the original error through next.
              }
            },
          );
          return next;
        })
        .whenComplete(() => _pendingWrites--);
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
    return _enqueueAsyncWrite(() {
      if (!isInitialized) {
        throw PersistenceFailure(
          commitState: PersistenceCommitState.notCommitted,
          cause: StateError('History database is closed'),
          stackTrace: StackTrace.current,
        );
      }
      final path = _dbPath;
      final generation = _generation;
      return () async {
        PersistenceFailure? committedFailure;
        try {
          await _writeDuration(path, snapshot, durationMs);
        } on PersistenceFailure catch (error) {
          if (error.commitState != PersistenceCommitState.committed) rethrow;
          committedFailure = error;
        } catch (error, stack) {
          throw PersistenceFailure(
            commitState: PersistenceCommitState.unknown,
            cause: error,
            stackTrace: stack,
          );
        }
        try {
          if (item.id == snapshot.id && item.type == snapshot.type) {
            item.readDurationMs += durationMs;
          }
          if (isInitialized && generation == _generation) {
            _cachePersistedHistory(snapshot.id, snapshot.type.value);
            notifyListeners();
          }
        } catch (error, stack) {
          final original = committedFailure;
          throw PersistenceFailure(
            commitState: PersistenceCommitState.committed,
            cause: original?.cause ?? error,
            stackTrace: original?.stackTrace ?? stack,
            cleanupFailures: original == null
                ? const []
                : [
                    ...original.cleanupFailures,
                    (error: error, stackTrace: stack),
                  ],
          );
        }
        if (committedFailure != null) {
          Error.throwWithStackTrace(
            committedFailure,
            committedFailure.stackTrace,
          );
        }
      };
    });
  }

  Future<void> waitForAsyncWrites() => _operations.access(_waitForLocalWrites);

  Future<void> _waitForLocalWrites() async {
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
      return _enqueueAsyncWrite(
        () => () async {
          if (!isInitialized || generation != _generation) return false;
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
        },
      );
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
    return _enqueueAsyncWrite(() {
      if (_database == null) throw StateError('History database is closed');
      final path = _dbPath;
      final generation = _generation;
      return () async {
        await _mutateDatabase(path, mutate);
        if (isInitialized && generation == _generation) {
          updateCache();
          notifyListeners();
        }
      };
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
    _initialization = null;
    _historyCache.clear();
    final database = _database;
    _database = null;
    database?.dispose();
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

class _HistoryInitialization {
  _HistoryInitialization(this.generation);
  final int generation;
  final result = Completer<void>();
  Future<void>? work;
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
