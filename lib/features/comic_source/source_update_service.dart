import 'dart:async';

import 'source_failure.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/app_dio.dart';

import 'comic_source_manager.dart';
import 'source.dart';
import 'source_repositories.dart';

/// Source updates shared by interactive and headless callers.
/// Presentation owns dialogs; the service owns request and commit lifetimes.
class SourceUpdateService {
  SourceUpdateService({Dio Function()? createDio})
    : _createDio = createDio ?? (() => AppDio());

  static final instance = SourceUpdateService();

  final Dio Function() _createDio;
  final _updating = <String, CancelToken>{};
  final _pending = <Future<void>>{};
  final _tokens = <CancelToken>{};
  bool _closed = false;
  Future<void>? _closing;
  CancelToken? _checkingToken;
  final _cleanupFailures = <({Object error, StackTrace stack})>[];
  Future<int>? _checking;
  SourceUpdateCheck? lastUpdateCheck;

  bool isUpdating(String sourceKey) => _updating.containsKey(sourceKey);

  void cancel(String sourceKey) {
    // Release synchronously so a retry can start before old I/O unwinds.
    _updating.remove(sourceKey)?.cancel();
  }

  Future<void> update(ComicSource source, {void Function()? onCommit}) {
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
      onCommit: onCommit,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<void> _update(ComicSource source, {void Function()? onCommit}) async {
    if (isUpdating(source.key)) {
      throw const SourceFailure(SourceFailureCode.updateInProgress);
    }
    final token = CancelToken();
    _updating[source.key] = token;
    _tokens.add(token);
    try {
      await _withClient((dio) async {
        final manager = ComicSourceManager();
        final store = SourceRepositories.instance;
        final origin = store.originFor(source.key);
        final repository = store.find(origin?.repositoryId);
        final url = await store.updateUrl(
          source,
          client: dio,
          cancelToken: token,
        );
        if (token.isCancelled) throw token.cancelError!;
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
            if (store.originFor(source.key)?.repositoryId !=
                    origin?.repositoryId ||
                store.originFor(source.key)?.url != origin?.url ||
                !identical(manager.find(source.key), source) ||
                (repository != null &&
                    store.find(repository.id)?.url != repository.url)) {
              throw const SourceFailure(SourceFailureCode.repositoryChanged);
            }
            // The serialized script commit is atomic; UI cancellation ends here.
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
      if (token.isCancelled) {
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

  Future<int> checkUpdates() {
    if (_closed) return Future.error(StateError('Source updates are closed'));
    if (_checking != null) return _checking!;
    final token = _checkingToken = CancelToken();
    final completion = Completer<int>();
    final result = _checking = completion.future.whenComplete(() {
      _checking = null;
      _checkingToken = null;
    });
    _checkUpdates(
      token,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<int> _checkUpdates(CancelToken token) async {
    final manager = ComicSourceManager();
    manager.updateAvailableUpdates({});
    final revision = SourceRepositories.instance.revision;
    final sources = manager
        .all()
        .where((source) => source.filePath.isNotEmpty)
        .toList();
    var result = await _withClient(
      (dio) => SourceRepositories.instance.checkUpdates(
        sources,
        client: dio,
        cancelToken: token,
      ),
    );
    if (_closed || token.isCancelled) {
      throw const SourceFailure(SourceFailureCode.cancelled);
    }
    if (revision != SourceRepositories.instance.revision) {
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
    lastUpdateCheck = result;
    manager.updateAvailableUpdates(result.updates);
    return result.updates.isEmpty && result.failures.isNotEmpty
        ? -1
        : result.updates.length;
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
