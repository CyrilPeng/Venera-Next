import 'dart:async';

import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/persistence_failure.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

import 'favorite_models.dart';

typedef FavoriteMetadataProgress = ({
  int total,
  int completed,
  int updated,
  int failed,
});
typedef FavoriteMetadataLoader =
    Future<Res<ComicDetails>?> Function(FavoriteItem item);

enum FavoriteMetadataStage { load, save }

FailureKind _kind(Object error) {
  if (error is RequestCancelled) return FailureKind.cancelled;
  if (error is UnsupportedError) return FailureKind.unsupported;
  if (error is FailureDetails) {
    if (error.cause is RequestCancelled) return FailureKind.cancelled;
    return error.kind;
  }
  return FailureKind.failed;
}

/// Keeps the stable favorite identity and the original error/stack. No source
/// lookup is needed to report a failure after that source has been replaced.
class FavoriteMetadataFailure extends OperationFailure {
  FavoriteMetadataFailure({
    required this.id,
    required this.type,
    required this.stage,
    required Object error,
    required StackTrace stack,
  }) : super(
         message: 'Favorite metadata $stage for $id ($type): $error',
         kind: _kind(error),
         cause: error,
         stackTrace: stack,
       );
  final String id;
  final int type;
  final FavoriteMetadataStage stage;
}

class FavoriteMetadataResult {
  FavoriteMetadataResult({
    required this.progress,
    required this.cancelled,
    required Iterable<FavoriteMetadataFailure> failures,
  }) : failures = List.unmodifiable(failures);
  final FavoriteMetadataProgress progress;
  final bool cancelled;
  final List<FavoriteMetadataFailure> failures;
}

class FavoriteMetadataBatchFailure implements Exception {
  FavoriteMetadataBatchFailure(Iterable<FavoriteMetadataFailure> failures)
    : failures = List.unmodifiable(failures);
  final List<FavoriteMetadataFailure> failures;
  @override
  String toString() => failures.map((failure) => failure.message).join('\n');
}

/// Fixed favorite inputs, four-at-a-time source reads, and one persistence
/// attempt for each successful read. Presentation and database ownership are
/// supplied by the caller; this operation owns only its request scope.
class FavoriteMetadataUpdate {
  FavoriteMetadataUpdate({
    required Iterable<FavoriteItem> comics,
    required FavoriteMetadataLoader load,
    required Future<void> Function(FavoriteItem item) save,
    required void Function() checkActive,
    void Function(FavoriteMetadataProgress)? onProgress,
  }) : _items = comics.map((item) => item.detached()).toList(),
       _load = load,
       _save = save,
       _checkOwner = checkActive,
       _onProgress = onProgress,
       _parent = RequestScope.current;

  final List<FavoriteItem> _items;
  final FavoriteMetadataLoader _load;
  final Future<void> Function(FavoriteItem item) _save;
  final void Function() _checkOwner;
  final void Function(FavoriteMetadataProgress)? _onProgress;
  final RequestScope? _parent;
  final _failures = <FavoriteMetadataFailure>[];
  RequestScope? _scope;
  Future<FavoriteMetadataResult>? _result;
  bool _cancelled = false;
  int _completed = 0;
  int _updated = 0;

  bool get isCancelled => _cancelled || _scope?.isCancelled == true;
  FavoriteMetadataProgress get progress => (
    total: _items.length,
    completed: _completed,
    updated: _updated,
    failed: _failures.length,
  );

  void cancel() {
    _cancelled = true;
    _scope?.cancel();
  }

  void checkActive() {
    if (isCancelled) throw const RequestCancelled();
    _checkOwner();
    _scope?.check();
  }

  Future<FavoriteMetadataResult> run() =>
      _result ??= Future<FavoriteMetadataResult>.microtask(_run);

  Future<FavoriteMetadataResult> _run() async {
    final scope = _scope = RequestScope(parent: _parent);
    if (_cancelled) scope.cancel();
    try {
      _publish();
      for (var index = 0; index < _items.length && !isCancelled; index += 4) {
        // Wait for the whole accepted batch, including errors and cancellation.
        await Future.wait(_items.skip(index).take(4).map(_update));
      }
      return FavoriteMetadataResult(
        progress: progress,
        cancelled: isCancelled,
        failures: _failures,
      );
    } finally {
      scope.dispose();
    }
  }

  Future<ComicDetails?> _read(FavoriteItem item) async {
    for (var attempt = 0; ; attempt++) {
      try {
        checkActive();
        return await _scope!.runToCompletion(() async {
          final result = await _load(item.detached());
          if (result == null) return null;
          if (result.error) {
            final failure = result.failure;
            if (failure != null) {
              Error.throwWithStackTrace(
                failure,
                failure.stackTrace ?? StackTrace.current,
              );
            }
            throw Exception(result.errorMessage);
          }
          return result.data;
        });
      } catch (error) {
        if (isCancelled || _kind(error) != FailureKind.failed || attempt == 2) {
          rethrow;
        }
      }
    }
  }

  Future<void> _update(FavoriteItem item) async {
    var stage = FavoriteMetadataStage.load;
    try {
      final info = await _read(item);
      checkActive();
      if (info == null) return;
      final tags = <String>[];
      for (final entry in info.tags.entries) {
        if (const {
          'author',
          'artist',
          'time',
        }.contains(entry.key.toLowerCase())) {
          continue;
        }
        for (final tag in entry.value) {
          tags.add('${entry.key}:$tag');
        }
      }
      final updated = FavoriteItem.withTime(
        id: item.id,
        type: item.type,
        time: item.time,
        name: info.title,
        coverPath: info.cover,
        author:
            info.subTitle ?? info.tags['author']?.firstOrNull ?? item.author,
        tags: tags,
      );
      stage = FavoriteMetadataStage.save;
      checkActive();
      // Cancellation cannot pretend a save which already started has ended.
      // Persistence failures do not reload the source or replay this write.
      await _save(updated);
      _updated++;
    } catch (error, stack) {
      if (_kind(error) == FailureKind.cancelled) {
        cancel();
      } else {
        if (stage == FavoriteMetadataStage.save &&
            error is PersistenceFailure &&
            error.commitState == PersistenceCommitState.committed) {
          _updated++;
        }
        _failures.add(
          FavoriteMetadataFailure(
            id: item.id,
            type: item.type.value,
            stage: stage,
            error: error,
            stack: stack,
          ),
        );
      }
    } finally {
      _completed++;
      _publish();
    }
  }

  void _publish() {
    try {
      _onProgress?.call(progress);
    } catch (_) {
      cancel();
      rethrow;
    }
  }
}
