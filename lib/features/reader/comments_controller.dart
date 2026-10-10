import 'dart:async';

import 'package:venera_next/features/comic_source/comic_source_api.dart'
    show Comment;
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/res.dart';
import 'package:venera_next/network/request_scope.dart';

/// Capabilities and metadata captured from one original chapter/source.
class ReaderChapterCommentsRequest {
  const ReaderChapterCommentsRequest({
    required this.identity,
    required this.sourceKey,
    required this.comicTitle,
    required this.chapterTitle,
    required this.isCurrent,
    required this.load,
    this.send,
    this.like,
    this.vote,
    this.replyComment,
    this.observeValidity,
  });

  final Object identity;
  final String sourceKey, comicTitle, chapterTitle;
  final bool Function() isCurrent;
  final Future<Res<List<Comment>>> Function(int page, String? replyTo) load;
  final Future<Res<bool>> Function(String text, String? replyTo)? send;
  final Future<Res<int?>> Function(String id, bool liked)? like;
  final Future<Res<int?>> Function(String id, bool up, bool cancel)? vote;
  final Comment? replyComment;

  /// Observes the original reader/source lifetime without starting work.
  /// The returned callback detaches only this subscription.
  final void Function() Function(void Function())? observeValidity;
  Object get key => (identity, replyComment?.id);

  ReaderChapterCommentsRequest replies(Comment comment) =>
      ReaderChapterCommentsRequest(
        identity: identity,
        sourceKey: sourceKey,
        comicTitle: comicTitle,
        chapterTitle: chapterTitle,
        isCurrent: isCurrent,
        load: load,
        send: send,
        like: like,
        vote: vote,
        replyComment: comment,
        observeValidity: observeValidity,
      );
}

/// Shared sidebar/embedded comment state. The original reader owns actual
/// pending calls; cancelling presentation never finishes an accepted Future.
class ReaderChapterCommentsController {
  ReaderChapterCommentsController({
    required this.request,
    required this.work,
    required this.includeComment,
    required this.onChanged,
    required this.onError,
  }) {
    _removeResume = work.addResumeListener(() {
      if (_needsResume && isCurrent) refresh();
    });
  }

  final ReaderChapterCommentsRequest request;
  final ImageWork work;
  final bool Function(Comment) includeComment;
  final void Function() onChanged;
  final void Function(Object, StackTrace) onError;
  late final void Function() _removeResume;
  final _tasks = <ImageWorkTask>{};
  ImageWorkTask? _readTask;
  int _generation = 0;
  bool _disposed = false, _needsResume = false;
  bool _loading = true, _loadingMore = false, _sending = false;
  List<Comment> _comments = [];
  Object? _error, _moreError;
  int _page = 1;
  int? _maxPage;

  bool get isCurrent => !_disposed && request.isCurrent();
  bool get loading => _loading;
  bool get sending => _sending;
  bool get hasMore => !_loading && _page < (_maxPage ?? _page + 1);
  List<Comment> get comments => List.unmodifiable(_comments);
  Object? get error => _error;
  Object? get moreError => _moreError;

  Future<void> refresh({bool notify = true}) {
    if (!isCurrent) return Future.value();
    _generation++;
    _readTask?.cancel();
    _readTask = null;
    _loading = true;
    _loadingMore = false;
    _error = _moreError = null;
    _comments = [];
    _page = 1;
    _maxPage = null;
    return _read(first: true, notify: notify);
  }

  Future<void> loadMore({bool notify = false}) {
    if (!isCurrent || !hasMore || _loadingMore) return Future.value();
    _moreError = null;
    return _read(first: false, notify: notify);
  }

  Future<void> _read({required bool first, required bool notify}) async {
    final generation = _generation;
    final scope = RequestScope();
    final task = work.start(
      onCancel: () {
        scope.cancel();
        if (generation == _generation) _needsResume = true;
      },
    );
    if (task == null) {
      scope.dispose();
      _needsResume = true;
      return;
    }
    _needsResume = false;
    _readTask = task;
    _tasks.add(task);
    if (!first) _loadingMore = true;
    bool current() =>
        isCurrent && !task.isCancelled && generation == _generation;
    try {
      if (notify) onChanged();
      task.check();
      if (!current()) return;
      final result = await scope.runToCompletion(
        () => request.load(first ? 1 : _page + 1, request.replyComment?.id),
      );
      _checkResult(result);
      if (!current()) return;
      final comments = result.data.where(includeComment).toList();
      if (first) {
        _comments = comments;
        _maxPage = result.subData as int?;
      } else {
        _comments.addAll(comments);
        _page++;
        if (_maxPage == null && result.data.isEmpty) _maxPage = _page;
      }
      _loading = false;
    } catch (error, _) {
      if (current()) {
        if (first) {
          _error = error;
          _loading = false;
        } else {
          _moreError = error;
        }
      }
    } finally {
      if (generation == _generation) {
        _needsResume = task.isCancelled;
        _loadingMore = false;
      }
      if (identical(_readTask, task)) _readTask = null;
      _tasks.remove(task);
      scope.dispose();
      task.finish();
      if (current()) onChanged();
    }
  }

  Future<bool> send(String text) async {
    if (!isCurrent || _sending || text.isEmpty || request.send == null) {
      return false;
    }
    _sending = true;
    try {
      final result = await mutate(
        () => request.send!(text, request.replyComment?.id),
      );
      if (result == null || !isCurrent) return false;
      // A successful send refreshes reads, never repeats the mutation.
      unawaited(refresh());
      return true;
    } finally {
      _sending = false;
      if (isCurrent) onChanged();
    }
  }

  Future<Res<T>?> mutate<T>(
    Future<Res<T>> Function() action, {
    bool Function()? canPresent,
  }) async {
    if (!isCurrent || canPresent?.call() == false) return null;
    final scope = RequestScope();
    final task = work.start(onCancel: scope.cancel);
    if (task == null) {
      scope.dispose();
      return null;
    }
    _tasks.add(task);
    bool current() =>
        isCurrent && !task.isCancelled && canPresent?.call() != false;
    var started = false;
    var confirmed = false;
    try {
      onChanged();
      task.check();
      if (!current()) return null;
      // The action is joined in its original scope. Result validation precedes
      // presentation checks so a late write failure remains with its owner.
      final result = await scope.runToCompletion(() async {
        started = true;
        final result = await action();
        _checkResult(result);
        confirmed = true;
        return result;
      });
      return current() ? result : null;
    } catch (error, stack) {
      if (confirmed && scope.isCancelled) return null;
      if (!started && error is ImageWorkTaskCancelled) return null;
      if (!current()) {
        if (started) task.recordFailure(error, stack);
      } else {
        try {
          onError(error, stack);
        } catch (reportError, reportStack) {
          task.recordFailure(error, stack);
          task.recordFailure(reportError, reportStack);
        }
      }
      return null;
    } finally {
      _tasks.remove(task);
      scope.dispose();
      task.finish();
    }
  }

  static void _checkResult(Res<dynamic> result) {
    if (!result.error) return;
    final failure = result.failure;
    Error.throwWithStackTrace(
      failure?.cause ?? failure ?? result.errorMessage!,
      failure?.stackTrace ?? StackTrace.current,
    );
  }

  Future<void> dispose() {
    _disposed = true;
    _generation++;
    _removeResume();
    final tasks = _tasks.toList();
    for (final task in tasks) {
      task.cancel();
    }
    return Future.wait(tasks.map((task) => task.done)).then<void>((_) {});
  }
}
