import 'dart:async';

import 'source_failure.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';

/// Source updates shared by interactive and headless callers.
/// Presentation owns dialogs; the service owns request and commit lifetimes.
class SourceUpdateService {
  SourceUpdateService({
    ComicSourceManager? manager,
    SourceRepositories? repositories,
    Dio Function()? createDio,
  }) : _manager = manager,
       _repositories = repositories ?? SourceRepositories.instance,
       _createDio = createDio ?? (() => AppDio());

  final Dio Function() _createDio;
  ComicSourceManager? _manager;
  final SourceRepositories _repositories;
  String? _dataPath;
  final _updating = <String, CancelToken>{};
  final _pending = <Future<void>>{};
  final _tokens = <CancelToken>{};
  bool _closed = false;
  Future<void>? _closing;
  CancelToken? _checkingToken;
  final _cleanupFailures = <({Object error, StackTrace stack})>[];
  Future<SourceUpdateReport>? _checking;

  bool get isClosed => _closed;
  bool isUpdating(String sourceKey) => _updating.containsKey(sourceKey);

  void cancel(String sourceKey, {CancelToken? request}) {
    if (request != null && !identical(_updating[sourceKey], request)) return;
    // Release synchronously so a retry can start before old I/O unwinds.
    _updating.remove(sourceKey)?.cancel();
  }

  ComicSourceManager _owner() {
    if (_closed) throw StateError('Source updates are closed');
    final manager = _manager ??= ComicSourceManager.current;
    if (manager == null || manager.isClosing) {
      throw StateError('Source update owner is unavailable');
    }
    _dataPath ??= App.dataPath;
    if (_dataPath != App.dataPath) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
    return manager;
  }

  void _validateTarget(ComicSourceManager manager, _SourceUpdateTarget target) {
    if (_dataPath != App.dataPath ||
        manager.isClosing ||
        !target.matches(manager, _repositories)) {
      throw const SourceFailure(SourceFailureCode.repositoryChanged);
    }
  }

  Future<void> update(
    ComicSource source, {
    void Function()? onCommit,
    CancelToken? cancelToken,
  }) => _startUpdate(source, onCommit: onCommit, cancelToken: cancelToken);

  Future<void> _startUpdate(
    ComicSource source, {
    _SourceUpdateTarget? expected,
    void Function()? onCommit,
    CancelToken? cancelToken,
  }) {
    if (_closed) return Future.error(StateError('Source updates are closed'));
    final completion = Completer<void>();
    final result = completion.future;
    late Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    _update(
      source,
      expected: expected,
      onCommit: onCommit,
      cancelToken: cancelToken,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<void> _update(
    ComicSource source, {
    _SourceUpdateTarget? expected,
    void Function()? onCommit,
    CancelToken? cancelToken,
  }) async {
    if (isUpdating(source.key)) {
      throw const SourceFailure(SourceFailureCode.updateInProgress);
    }
    final token = cancelToken ?? CancelToken();
    _updating[source.key] = token;
    _tokens.add(token);
    var mutationAccepted = false;
    try {
      if (token.isCancelled) throw token.cancelError!;
      final manager = _owner();
      final store = _repositories;
      final target = expected ?? _SourceUpdateTarget.capture(source, store);
      _validateTarget(manager, target);
      await _withClient((dio) async {
        final repository = target.repository;
        final url = await store.updateUrl(
          source,
          client: dio,
          cancelToken: token,
        );
        if (token.isCancelled) throw token.cancelError!;
        _validateTarget(manager, target);
        final res = await dio.get<String>(
          url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'cache-time': 'no'},
          ),
        );
        if (token.isCancelled) throw token.cancelError!;
        await manager.replaceScript(
          source,
          res.data!,
          validate: () {
            if (token.isCancelled) throw token.cancelError!;
            _validateTarget(manager, target);
            // The serialized script commit is atomic; UI cancellation ends here.
            mutationAccepted = true;
            onCommit?.call();
          },
          origin: repository == null
              ? null
              : SourceOrigin(
                  kind: 'repository',
                  repositoryId: repository.id,
                  repositoryName: repository.name,
                  url: url,
                ),
        );
      });
    } catch (error, stack) {
      if (token.isCancelled &&
          !mutationAccepted &&
          error is! SourceUpdateCloseFailure) {
        throw SourceFailure(
          SourceFailureCode.cancelled,
          cause: error,
          stackTrace: stack,
        );
      }
      Log.error('Update comic source', '$error\n$stack');
      rethrow;
    } finally {
      _tokens.remove(token);
      if (identical(_updating[source.key], token)) {
        _updating.remove(source.key);
      }
    }
  }

  Future<SourceUpdateReport> checkUpdates() {
    if (_closed) return Future.error(StateError('Source updates are closed'));
    if (_checking != null) return _checking!;
    final token = _checkingToken = CancelToken();
    final completion = Completer<SourceUpdateReport>();
    final result = _checking = completion.future.whenComplete(() {
      _checking = null;
      _checkingToken = null;
    });
    _checkUpdates(
      token,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<SourceUpdateReport> _checkUpdates(CancelToken token) async {
    final manager = _owner();
    final store = _repositories;
    manager.updateAvailableUpdates({});
    final revision = store.revision;
    final sources = manager
        .all()
        .where((source) => source.filePath.isNotEmpty)
        .toList();
    final targets = {
      for (final source in sources)
        source.key: _SourceUpdateTarget.capture(source, store),
    };
    var result = await _withClient(
      (dio) => store.checkUpdates(sources, client: dio, cancelToken: token),
    );
    if (_closed || token.isCancelled) {
      throw const SourceFailure(SourceFailureCode.cancelled);
    }
    _owner();
    if (revision != store.revision ||
        targets.values.any((target) => !target.matches(manager, store))) {
      result = SourceUpdateCheck(
        updates: {},
        failures: [
          const SourceCheckFailure(
            SourceFailure(SourceFailureCode.repositoryChanged),
          ),
        ],
        checked: 0,
        skipped: sources.length,
      );
    }
    final report = SourceUpdateReport._(this, result, targets);
    manager.updateAvailableUpdates(report.updates);
    return report;
  }

  Future<T> _withClient<T>(Future<T> Function(Dio) action) async {
    final dio = _createDio();
    final adapter = dio.httpClientAdapter;
    Object? cause;
    StackTrace? causeStack;
    try {
      return await action(dio);
    } catch (error, stack) {
      cause = error;
      causeStack = stack;
      rethrow;
    } finally {
      final failures = <({Object error, StackTrace stack})>[];
      Future<void> release(FutureOr<void> Function() close) async {
        try {
          await close();
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
      }

      await release(() => dio.close(force: true));
      if (adapter is RHttpAdapter) {
        await release(adapter.waitForIdle);
      }
      if (failures.isNotEmpty) {
        final failure = SourceUpdateCloseFailure(
          failures,
          cause: cause,
          causeStack: causeStack,
        );
        _cleanupFailures.add((error: failure, stack: StackTrace.current));
        throw failure;
      }
    }
  }

  Future<void> closeAndWait() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    for (final token in [..._tokens, ?_checkingToken]) {
      token.cancel();
    }
    return _closing = _drain();
  }

  Future<void> _drain() async {
    final failures = <({Object error, StackTrace stack})>[];
    final checking = _checking;
    if (checking != null) {
      try {
        await checking;
      } on SourceFailure catch (error, stack) {
        if (error.code != SourceFailureCode.cancelled) {
          failures.add((error: error, stack: stack));
        }
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
    for (final failure in _cleanupFailures) {
      if (!failures.any(
        (existing) => identical(existing.error, failure.error),
      )) {
        failures.add(failure);
      }
    }
    if (failures.isNotEmpty) throw SourceUpdateCloseFailure(failures);
  }
}

/// The exact result and source identities accepted by one check. Updating a
/// target validates its own inputs, so another target's successful commit does
/// not invalidate the rest of this report by changing a global revision.
class SourceUpdateReport extends SourceUpdateCheck {
  SourceUpdateReport._(
    this._service,
    SourceUpdateCheck result,
    Map<String, _SourceUpdateTarget> targets,
  ) : _targets = Map.unmodifiable(targets),
      sources = Map.unmodifiable({
        for (final entry in targets.entries) entry.key: entry.value.source,
      }),
      super(
        updates: Map.unmodifiable(result.updates),
        failures: List.unmodifiable(result.failures),
        checked: result.checked,
        skipped: result.skipped,
      );

  final SourceUpdateService _service;
  final Map<String, _SourceUpdateTarget> _targets;
  final Map<String, ComicSource> sources;

  Future<void> update(
    String key, {
    void Function()? onCommit,
    CancelToken? cancelToken,
  }) {
    final target = _targets[key];
    if (target == null || !updates.containsKey(key)) {
      return Future.error(const SourceFailure(SourceFailureCode.missingSource));
    }
    return _service._startUpdate(
      target.source,
      expected: target,
      onCommit: onCommit,
      cancelToken: cancelToken,
    );
  }
}

class _SourceUpdateTarget {
  const _SourceUpdateTarget(this.source, this.origin, this.repository);

  factory _SourceUpdateTarget.capture(
    ComicSource source,
    SourceRepositories store,
  ) {
    final origin = store.originFor(source.key);
    return _SourceUpdateTarget(
      source,
      origin,
      store.find(origin?.repositoryId),
    );
  }

  final ComicSource source;
  final SourceOrigin? origin;
  final SourceRepository? repository;

  bool matches(ComicSourceManager manager, SourceRepositories store) {
    final currentOrigin = store.originFor(source.key);
    final currentRepository = store.find(currentOrigin?.repositoryId);
    return identical(manager.find(source.key), source) &&
        currentOrigin?.kind == origin?.kind &&
        currentOrigin?.repositoryId == origin?.repositoryId &&
        currentOrigin?.url == origin?.url &&
        currentRepository?.id == repository?.id &&
        currentRepository?.url == repository?.url;
  }
}

class SourceUpdateCloseFailure implements Exception {
  SourceUpdateCloseFailure(
    Iterable<({Object error, StackTrace stack})> failures, {
    this.cause,
    this.causeStack,
  }) : failures = List.unmodifiable(failures);
  final Object? cause;
  final StackTrace? causeStack;
  final List<({Object error, StackTrace stack})> failures;
  @override
  String toString() =>
      'Source update cleanup failed: ${failures.map((failure) => failure.error).join('; ')}';
}
