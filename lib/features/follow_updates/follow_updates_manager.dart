import 'dart:async';
import 'dart:convert';

import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

import 'follow_update_queue.dart';
import 'follow_update_task.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;
  final bool cancelled;
  ComicUpdateResult(this.updated, this.errorMessage, {this.cancelled = false});
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo comic,
  String folder, {
  RequestScope? scope,
  int? generation,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final request = RequestScope(parent: scope, timeout: timeout);
  if (FollowUpdateJob._exitPreparation != null) {
    request.cancel();
    request.dispose();
    return ComicUpdateResult(false, null, cancelled: true);
  }
  final done = Completer<void>();
  FollowUpdateJob._updates[request] = done.future;
  try {
    request.check();
    final source = comic.type.comicSource;
    if (source?.loadComicInfo == null) {
      return ComicUpdateResult(false, 'Comic source not found');
    }
    final favorites = LocalFavoritesManager();
    final sourceGeneration = generation ?? favorites.connectionGeneration;
    if (sourceGeneration != favorites.connectionGeneration) {
      throw StateError('Favorites database changed');
    }
    // Transient failures are retried by the JS bridge, once per source call.
    final response = await request.run(() => source!.loadComicInfo!(comic.id));
    request.check();
    if (response.error) return ComicUpdateResult(false, response.errorMessage);
    final info = response.data;
    final tags = <String>[];
    for (final entry in info.tags.entries) {
      if (const [
        'author',
        'artist',
        'time',
      ].contains(entry.key.toLowerCase())) {
        continue;
      }
      tags.addAll(entry.value.map((tag) => '${entry.key}:$tag'));
    }
    request.check();
    final updated = await favorites.applyFollowUpdate(
      folder,
      FavoriteItem(
        id: comic.id,
        name: info.title,
        coverPath: info.cover,
        author:
            info.subTitle ?? info.tags['author']?.firstOrNull ?? comic.author,
        type: comic.type,
        tags: tags,
      ),
      info.findUpdateTime(),
      generation: sourceGeneration,
      checkActive: request.check,
    );
    return ComicUpdateResult(updated, null);
  } catch (error, stack) {
    if (scope?.isCancelled == true || error is RequestCancelled) {
      return ComicUpdateResult(false, null, cancelled: true);
    }
    Log.error('Check Updates', error, stack);
    return ComicUpdateResult(false, error.toString());
  } finally {
    request.dispose();
    FollowUpdateJob._updates.remove(request);
    done.complete();
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;
  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
  double get fraction => total == 0 ? 1 : current / total;
}

/// One application-wide check. Replacing a job cancels its queue and writes.
class FollowUpdateJob implements FollowUpdateTask {
  FollowUpdateJob(this.folder, this.ignoreCheckTime) {
    _controller = StreamController<UpdateProgress>(
      onListen: _start,
      onCancel: cancel,
    );
    // Existing callers consume progress only. Keep that error channel usable
    // while lifecycle owners can independently await a failed completion.
    _done.future.ignore();
    if (_exitPreparation == null) {
      _jobs.add(this);
    } else {
      cancel();
    }
  }
  static FollowUpdateJob? _active;
  static final _jobs = <FollowUpdateJob>{};
  static final _updates = <RequestScope, Future<void>>{};
  static Future<void Function()>? _exitPreparation;
  static bool get isChecking => _active != null && !_active!._scope.isCancelled;
  static void cancelActive() => _active?.cancel();

  /// Freeze both jobs and direct updates, then cancel their remaining checks.
  /// All accepted writes and final notifications settle before this returns.
  /// Cancelled source calls may still finish their own underlying transport;
  /// their late results cannot enter the update's guarded database writes.
  static Future<void Function()> prepareForExit() {
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final ready = Completer<void Function()>();
    final preparation = _exitPreparation = ready.future;
    final jobs = _jobs.toList();
    final updates = Map<RequestScope, Future<void>>.of(_updates);
    for (final job in jobs) {
      job.cancel();
    }
    for (final scope in updates.keys) {
      scope.cancel();
    }
    void release() {
      if (identical(_exitPreparation, preparation)) _exitPreparation = null;
    }

    Future.wait([for (final job in jobs) job.done, ...updates.values]).then(
      (_) => ready.complete(release),
      onError: (Object error, StackTrace stack) {
        release();
        ready.completeError(error, stack);
      },
    );
    return preparation;
  }

  final String folder;
  final bool ignoreCheckTime;
  final _scope = RequestScope();
  final _done = Completer<void>();
  bool _started = false;
  bool _finished = false;
  late final StreamController<UpdateProgress> _controller;
  Stream<UpdateProgress> get progress => _controller.stream;
  @override
  Stream<int> get updatedCounts => progress.map((value) => value.updated);
  @override
  Future<void> get done => _done.future;
  bool get isCancelled => _scope.isCancelled;
  @override
  void cancel() {
    if (_finished) return;
    _scope.cancel();
    if (!_started) _finish();
  }

  void _start() {
    if (_finished) return;
    if (_exitPreparation != null || isCancelled) {
      cancel();
      return;
    }
    _started = true;
    _active?.cancel();
    _active = this;
    unawaited(_run());
  }

  void _finish([Object? failure, StackTrace? failureStack]) {
    _finished = true;
    if (identical(_active, this)) _active = null;
    _jobs.remove(this);
    _scope.dispose();
    if (failure != null) {
      if (_controller.hasListener) _controller.addError(failure, failureStack);
      _done.completeError(failure, failureStack);
    } else {
      _done.complete();
    }
    // A paused or absent subscriber must not delay task ownership release.
    unawaited(_controller.close());
  }

  Future<void> _run() async {
    var current = 0;
    var errors = 0;
    var updated = 0;
    final pending = <Future<void>>[];
    Object? failure;
    StackTrace? failureStack;
    try {
      final favorites = LocalFavoritesManager();
      final generation = favorites.connectionGeneration;
      final comics = favorites
          .getComicsWithUpdatesInfo(folder)
          .where(
            (comic) =>
                ignoreCheckTime ||
                comic.lastCheckTime == null ||
                DateTime.now().difference(comic.lastCheckTime!).inDays >= 1,
          )
          .toList();
      void emit([FavoriteItemWithUpdateInfo? comic, String? error]) {
        if (!isCancelled) {
          _controller.add(
            UpdateProgress(
              comics.length,
              current,
              errors,
              updated,
              comic,
              error,
            ),
          );
        }
      }

      emit();
      await runFollowUpdateTasks(
        comics,
        scope: _scope,
        sourceKey: (comic) => comic.type.sourceKey,
        run: (comic) {
          final work = () async {
            final result = await updateComic(
              comic,
              folder,
              scope: _scope,
              generation: generation,
            );
            if (isCancelled || result.cancelled) return;
            current++;
            if (result.updated) updated++;
            if (result.errorMessage != null) errors++;
            emit(comic, result.errorMessage);
          }();
          pending.add(work);
          return work;
        },
      );
    } catch (error, stack) {
      if (error is! RequestCancelled) {
        failure = error;
        failureStack = stack;
      }
    } finally {
      try {
        // The queue can finish its cancellation race before the underlying
        // update callback has run its finally block. Join that business work.
        await Future.wait(pending);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
      try {
        if (updated > 0) LocalFavoritesManager().notifyChanges();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      } finally {
        _finish(failure, failureStack);
      }
    }
  }
}

Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) =>
    FollowUpdateJob(folder, ignoreCheckTime).progress;

/// The preview represents the user's follow-updates folder, while the update
/// badge and count are separate hints on top of that list.
List<FavoriteItemWithUpdateInfo> getFollowUpdatesPreviewComics(String folder) {
  return LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate).toList();
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'type': c.type.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}
