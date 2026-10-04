import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/foundation/throttled_task_runner.dart';
import 'webdav_library_cache.dart';
import 'webdav_library_discovery.dart';
import 'webdav_library_entries.dart';
import 'webdav_library_session.dart';
import 'webdav_library_settings.dart';
import 'webdav_library_snapshot_store.dart';

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

class WebDavLibrarySyncLifecycleFailure implements Exception {
  WebDavLibrarySyncLifecycleFailure(
    Iterable<({String operation, Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({String operation, Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'WebDAV synchronization cleanup failed: '
      '${failures.map((failure) => '${failure.operation}: ${failure.error}').join('; ')}';
}

/// Owns synchronization runs; transport/session/storage lifetimes stay with the caller.
class WebDavLibrarySynchronizer {
  WebDavLibrarySynchronizer({
    required WebDavLibraryCache cache,
    required WebDavLibrarySnapshotStore snapshots,
    required WebDavLibrarySettings Function() readSettings,
    required WebDavLibrarySession Function() currentSession,
    required void Function() onContentChanged,
    int Function()? nowMilliseconds,
  }) : _cache = cache,
       _snapshots = snapshots,
       _readSettings = readSettings,
       _currentSession = currentSession,
       _onContentChanged = onContentChanged,
       _nowMilliseconds = nowMilliseconds ?? _systemTime;

  static int _systemTime() => DateTime.now().millisecondsSinceEpoch;
  final WebDavLibraryCache _cache;
  final WebDavLibrarySnapshotStore _snapshots;
  final WebDavLibrarySettings Function() _readSettings;
  final WebDavLibrarySession Function() _currentSession;
  final void Function() _onContentChanged;
  final int Function() _nowMilliseconds;
  final _status = ValueNotifier<WebDavLibrarySyncStatus>(
    const WebDavLibrarySyncStatus(isSyncing: false, lastSuccessfulSync: 0),
  );
  ValueListenable<WebDavLibrarySyncStatus> get status => _status;
  _WebDavLibrarySyncRun? _syncRun;
  final _runs = <_WebDavLibrarySyncRun>{};
  Future<void>? _closing;
  Future<void Function()>? _exitPreparation;
  bool _disposed = false;
  int _generation = 0;

  void invalidate() {
    if (_disposed) return;
    _generation++;
    _syncRun = null;
    try {
      _snapshots.clear();
    } finally {
      _status.value = const WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: 0,
      );
    }
  }

  /// Stop admissions and invalidate every run immediately. The caller retains
  /// its cache and transport until closeAndWait has joined outstanding work.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _syncRun = null;
    final ready = Completer<void>();
    _closing = ready.future;
    final failures = <({String operation, Object error, StackTrace stack})>[];
    _attemptCleanup('snapshots', _snapshots.clear, failures);
    _attemptCleanup('status', _status.dispose, failures);
    _drainRuns(
      _runs.toList(),
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

  /// Hold automatic, manual and index-triggered work until this preparation is
  /// released. Replaced runs stay owned until their actual futures finish.
  Future<void Function()> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('WebDAV synchronizer is disposed'));
    }
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final ready = Completer<void Function()>();
    final preparation = _exitPreparation = ready.future;
    _generation++;
    _syncRun = null;
    final failures = <({String operation, Object error, StackTrace stack})>[];
    _attemptCleanup('snapshots', _snapshots.clear, failures);
    _attemptCleanup('status', () {
      _status.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: _status.value.lastSuccessfulSync,
      );
    }, failures);
    void release() {
      if (identical(_exitPreparation, preparation)) _exitPreparation = null;
    }

    _drainRuns(_runs.toList(), failures).then(
      (_) => ready.complete(release),
      onError: (Object error, StackTrace stack) {
        release();
        ready.completeError(error, stack);
      },
    );
    return preparation;
  }

  void _attemptCleanup(
    String operation,
    void Function() cleanup,
    List<({String operation, Object error, StackTrace stack})> failures,
  ) {
    try {
      cleanup();
    } catch (error, stack) {
      failures.add((operation: operation, error: error, stack: stack));
    }
  }

  Future<void> _drainRuns(
    List<_WebDavLibrarySyncRun> runs,
    List<({String operation, Object error, StackTrace stack})> failures,
  ) async {
    await Future.wait(
      runs.map((run) async {
        try {
          await run.complete;
        } catch (error, stack) {
          failures.add((
            operation: 'synchronization',
            error: error,
            stack: stack,
          ));
        }
      }),
    );
    if (failures.isNotEmpty) throw WebDavLibrarySyncLifecycleFailure(failures);
  }

  void updateSyncStatusFromCache() {
    if (_disposed || _exitPreparation != null) return;
    final session = _currentSession();
    if (_status.value.isSyncing) return;
    final config = session.config;
    if (!config.isValid) return;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    if (_status.value.lastSuccessfulSync == lastSync) return;
    _status.value = WebDavLibrarySyncStatus(
      isSyncing: false,
      lastSuccessfulSync: lastSync,
    );
  }

  void checkForAutomaticSync() {
    if (_disposed || _exitPreparation != null) return;
    updateSyncStatusFromCache();
    if (_disposed || _exitPreparation != null) return;
    final configuration = _readSettings();
    final config = configuration.connection;
    if (!config.isValid || !configuration.autoSync) {
      return;
    }
    final interval = configuration.intervalMinutes;
    final lastSync = _cache.lastSuccessfulSync(config.cacheKey);
    final elapsed = _nowMilliseconds() - lastSync;
    if (lastSync == 0 ||
        elapsed >= Duration(minutes: interval).inMilliseconds) {
      unawaited(synchronize());
    }
  }

  Future<Res<bool>> ensureIndex(WebDavLibrarySession session) async {
    if (_disposed) throw StateError('WebDAV synchronizer is disposed');
    if (_exitPreparation != null) {
      return const Res.error('WebDAV request cancelled');
    }
    session.check();
    final config = session.config;
    if (_cache.hasDirectoryIndex(config.cacheKey)) {
      checkForAutomaticSync();
      return const Res(true);
    }
    return (await _startSynchronization(session: session).indexReady);
  }

  Future<Res<bool>> synchronize({bool force = false}) {
    if (_disposed) throw StateError('WebDAV synchronizer is disposed');
    if (_exitPreparation != null) {
      return Future.value(const Res.error('WebDAV request cancelled'));
    }
    final session = _currentSession();
    final config = session.config;
    if (!config.isValid) {
      return Future.value(
        const Res.error('Invalid WebDAV comic library configuration'),
      );
    }
    return _startSynchronization(session: session, force: force).complete;
  }

  _WebDavLibrarySyncRun _startSynchronization({
    required WebDavLibrarySession session,
    bool force = false,
  }) {
    if (_disposed) throw StateError('WebDAV synchronizer is disposed');
    if (_exitPreparation != null) throw const WebDavLibraryCancelled();
    final current = _syncRun;
    if (current != null) return current;

    final generation = _generation;
    final runSession = WebDavLibrarySession(
      session.config,
      session.ops,
      isCurrent: () =>
          !_disposed && _generation == generation && session.isActive,
    );
    final indexReady = Completer<Res<bool>>();
    indexReady.future.ignore();
    late final _WebDavLibrarySyncRun run;
    final complete =
        Future<Res<bool>>.microtask(() async {
          try {
            return await _runSynchronization(
              runSession,
              indexReady,
              force: force,
            );
          } catch (error, stack) {
            if (!indexReady.isCompleted) indexReady.completeError(error, stack);
            rethrow;
          }
        }).whenComplete(() {
          _runs.remove(run);
          if (identical(_syncRun, run)) _syncRun = null;
        });
    run = _WebDavLibrarySyncRun(
      indexReady: indexReady.future,
      complete: complete,
    );
    _syncRun = run;
    _runs.add(run);
    complete.ignore();
    return run;
  }

  Future<Res<bool>> _runSynchronization(
    WebDavLibrarySession session,
    Completer<Res<bool>> indexReady, {
    required bool force,
  }) async {
    final config = session.config;
    final configKey = config.cacheKey;
    var previousLastSync = 0;
    try {
      session.check();
      previousLastSync = _cache.lastSuccessfulSync(configKey);
      _status.value = WebDavLibrarySyncStatus(
        isSyncing: true,
        lastSuccessfulSync: previousLastSync,
      );
      final rootEntries = List<WebDavLibraryEntry>.from(
        await session.readDir(config.remotePath),
      );
      session.check();
      final hadDirectoryIndex = _cache.hasDirectoryIndex(configKey);
      final previous = _cache.all(configKey);
      final provisionalDirectories = webDavSortedDirectories(rootEntries);
      if (!hadDirectoryIndex) {
        _cache.replaceDirectoryIndex(configKey, [
          for (var index = 0; index < provisionalDirectories.length; index++)
            WebDavLibraryRemoteDirectory(
              id: provisionalDirectories[index].name,
              sortIndex: index,
              eTag: provisionalDirectories[index].eTag,
              modifiedAt: provisionalDirectories[index].modifiedAt,
            ),
        ]);
      }
      if (!indexReady.isCompleted) {
        indexReady.complete(const Res(true));
      }
      _onContentChanged();
      final discovered = await WebDavLibraryDiscovery(session).discover(
        rootEntries: rootEntries,
        canReuse: (directory) {
          final cached = previous[directory.name];
          return !force &&
              cached != null &&
              cached.isReady &&
              cached.hasSameRemoteVersion(
                eTag: directory.eTag,
                modifiedAt: directory.modifiedAt,
              );
        },
      );
      session.check();
      final remoteDirectories = <WebDavLibraryRemoteDirectory>[
        for (var index = 0; index < discovered.length; index++)
          WebDavLibraryRemoteDirectory(
            id: discovered[index].id,
            sortIndex: index,
            eTag: discovered[index].eTag,
            modifiedAt: discovered[index].modifiedAt,
          ),
      ];
      _cache.replaceDirectoryIndex(configKey, remoteDirectories);
      _onContentChanged();

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

      session.check();
      var processed = 0;
      var failed = 0;
      _status.value = WebDavLibrarySyncStatus(
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
            final discoveredDirectory = discovered.firstWhere(
              (candidate) => candidate.id == directory.id,
            );
            await _snapshots.load(
              session,
              directory.id,
              forceRefresh: true,
              remoteDirectory: directory,
              rootEntries: discoveredDirectory.entries,
            );
          } catch (e) {
            if (e is WebDavLibraryCancelled) rethrow;
            failed++;
            Log.warning(
              'WebDAV Library',
              'Failed to inspect ${directory.id}: $e',
            );
          } finally {
            processed++;
            if (session.isActive &&
                (processed % 5 == 0 || processed == toRefresh.length)) {
              _onContentChanged();
              session.check();
              _status.value = WebDavLibrarySyncStatus(
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

      session.check();
      final now = _nowMilliseconds();
      _cache.setLastSuccessfulSync(configKey, now);
      _status.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: now,
        processed: processed,
        total: toRefresh.length,
        failed: failed,
      );
      session.check();
      _onContentChanged();
      return const Res(true);
    } catch (e, s) {
      if (!session.isActive) {
        const result = Res<bool>.error('WebDAV request cancelled');
        if (!indexReady.isCompleted) indexReady.complete(result);
        return result;
      }
      Log.error('WebDAV Library Sync', e, s);
      final result = Res<bool>.error(e.toString());
      if (!indexReady.isCompleted) {
        indexReady.complete(result);
      }
      _status.value = WebDavLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: previousLastSync,
        errorMessage: e.toString(),
      );
      return result;
    }
  }
}
