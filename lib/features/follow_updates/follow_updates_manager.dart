import 'dart:async';
import 'dart:convert';

import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/favorites/favorites.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/network/request_scope.dart';

import 'follow_update_queue.dart';

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
  Duration timeout = const Duration(seconds: 45),
}) async {
  final request = RequestScope(parent: scope, timeout: timeout);
  try {
    final source = comic.type.comicSource;
    if (source?.loadComicInfo == null) {
      return ComicUpdateResult(false, 'Comic source not found');
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
    LocalFavoritesManager().updateInfo(
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
      false,
    );
    final updateTime = info.findUpdateTime();
    final updated = updateTime != null && updateTime != comic.updateTime;
    if (updated) {
      LocalFavoritesManager().updateUpdateTime(
        folder,
        comic.id,
        comic.type,
        updateTime,
      );
    } else {
      LocalFavoritesManager().updateCheckTime(folder, comic.id, comic.type);
    }
    return ComicUpdateResult(updated, null);
  } catch (error, stack) {
    if (scope?.isCancelled == true || error is RequestCancelled) {
      return ComicUpdateResult(false, null, cancelled: true);
    }
    Log.error('Check Updates', error, stack);
    return ComicUpdateResult(false, error.toString());
  } finally {
    request.dispose();
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
class FollowUpdateJob {
  FollowUpdateJob(this.folder, this.ignoreCheckTime) {
    _controller = StreamController<UpdateProgress>(
      onListen: () => unawaited(_run()),
      onCancel: cancel,
    );
  }
  static FollowUpdateJob? _active;
  static bool get isChecking => _active != null && !_active!._scope.isCancelled;
  static void cancelActive() => _active?.cancel();
  final String folder;
  final bool ignoreCheckTime;
  final _scope = RequestScope();
  bool _finished = false;
  late final StreamController<UpdateProgress> _controller;
  Stream<UpdateProgress> get progress => _controller.stream;
  bool get isCancelled => _scope.isCancelled;
  void cancel() {
    if (!_finished) _scope.cancel();
  }

  Future<void> _run() async {
    if (isCancelled) {
      unawaited(_controller.close());
      return;
    }
    _active?.cancel();
    _active = this;
    var current = 0;
    var errors = 0;
    var updated = 0;
    try {
      final comics = LocalFavoritesManager()
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
        run: (comic) async {
          final result = await updateComic(comic, folder, scope: _scope);
          if (isCancelled || result.cancelled) return;
          current++;
          if (result.updated) updated++;
          if (result.errorMessage != null) errors++;
          emit(comic, result.errorMessage);
        },
      );
    } catch (error, stack) {
      if (error is! RequestCancelled && _controller.hasListener) {
        _controller.addError(error, stack);
      }
    } finally {
      _finished = true;
      if (updated > 0) LocalFavoritesManager().notifyChanges();
      if (identical(_active, this)) _active = null;
      _scope.dispose();
      unawaited(_controller.close());
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
