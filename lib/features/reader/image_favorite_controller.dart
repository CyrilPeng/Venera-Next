import 'dart:async';

import 'package:venera_next/features/history/history_api.dart'
    show ImageFavoriteResult;
import 'package:venera_next/foundation/image_work.dart';

enum ReaderImageFavoriteStatus {
  unavailable,
  loading,
  collected,
  uncollected,
  selectImage,
  failed,
}

class ReaderImageFavoriteQuery {
  const ReaderImageFavoriteQuery({
    required this.key,
    required this.read,
    required this.isCurrent,
  });
  final Object key;
  final Future<bool?> Function() read;
  final bool Function() isCurrent;
}

/// The reader adapter captures metadata and the original storage before picking.
class ReaderImageFavoriteRequest {
  const ReaderImageFavoriteRequest({
    required this.supported,
    required this.isCurrent,
    required this.toggle,
  });
  final bool supported;
  final bool Function() isCurrent;
  final Future<ImageFavoriteResult> Function(
    int index,
    void Function() checkActive,
  )
  toggle;
}

/// Owns status reads and one collection attempt. Read retries never replay a
/// toggle, and cancellation retains actual pending I/O in the original ImageWork.
class ReaderImageFavoriteController {
  ReaderImageFavoriteController({
    required this.work,
    required this.onChanged,
    required this.onResult,
    required this.onUnsupported,
    required this.onError,
    required this.cancelSelection,
  }) {
    _removeResume = work.addResumeListener(refresh);
  }
  final ImageWork work;
  final void Function() onChanged, onUnsupported, cancelSelection;
  final void Function(ImageFavoriteResult) onResult;
  final void Function(Object, StackTrace) onError;
  late final void Function() _removeResume;
  ReaderImageFavoriteQuery? _query;
  ImageWorkTask? _readTask, _collectTask;
  final _tasks = <ImageWorkTask>{};
  int _revision = 0;
  bool _disposed = false;
  ReaderImageFavoriteStatus _status = ReaderImageFavoriteStatus.unavailable;
  Object? _error;
  StackTrace? _errorStack;
  ReaderImageFavoriteStatus get status => _status;
  Object? get error => _error;
  StackTrace? get errorStack => _errorStack;
  bool get collecting => _collectTask != null;
  bool get canCollect =>
      !collecting &&
      (status == ReaderImageFavoriteStatus.collected ||
          status == ReaderImageFavoriteStatus.uncollected ||
          status == ReaderImageFavoriteStatus.selectImage);

  /// Called while building; the synchronous state change needs no notification.
  void bind(ReaderImageFavoriteQuery? query) {
    if (_disposed ||
        (_query?.key == query?.key &&
            (query == null ||
                (query.isCurrent() && _query?.isCurrent() == true)))) {
      return;
    }
    _query = query;
    _startRead(notify: false);
  }

  void retry() {
    if (status == ReaderImageFavoriteStatus.failed) refresh();
  }

  /// Storage notifications only invalidate; the next build starts the read
  /// outside the publisher's data-access scope.
  void invalidate() {
    if (_disposed) return;
    _query = null;
    _revision++;
    _readTask?.cancel();
    _status = ReaderImageFavoriteStatus.unavailable;
    onChanged();
  }

  void refresh() {
    if (!_disposed) _startRead(notify: true);
  }

  void _startRead({required bool notify}) {
    final revision = ++_revision;
    _readTask?.cancel();
    _readTask = null;
    _error = null;
    _errorStack = null;
    final query = _query;
    final task = query != null && query.isCurrent() ? work.start() : null;
    _status = task == null
        ? ReaderImageFavoriteStatus.unavailable
        : ReaderImageFavoriteStatus.loading;
    if (task != null) {
      _readTask = task;
      _tasks.add(task);
      unawaited(_read(query!, task, revision));
    }
    if (notify) onChanged();
  }

  Future<void> _read(
    ReaderImageFavoriteQuery query,
    ImageWorkTask task,
    int revision,
  ) async {
    bool current() =>
        !_disposed &&
        !task.isCancelled &&
        revision == _revision &&
        query.isCurrent();
    try {
      final collected = await task.read(query.read);
      if (current()) {
        _status = collected == null
            ? ReaderImageFavoriteStatus.selectImage
            : collected
            ? ReaderImageFavoriteStatus.collected
            : ReaderImageFavoriteStatus.uncollected;
      }
    } catch (failure, stack) {
      if (failure is! ImageWorkTaskCancelled && current()) {
        _error = failure;
        _errorStack = stack;
        _status = ReaderImageFavoriteStatus.failed;
      }
      // A failed status read is recoverable UI state, not a failed write.
    } finally {
      final notify = current();
      if (identical(_readTask, task)) _readTask = null;
      _tasks.remove(task);
      task.finish();
      if (notify) onChanged();
    }
  }

  Future<void> collect(
    ReaderImageFavoriteRequest? request,
    Future<int?> Function() select,
  ) async {
    if (_disposed || !canCollect || request == null || !request.isCurrent()) {
      return;
    }
    final task = work.start(cancelSelection: cancelSelection);
    if (task == null) return;
    _collectTask = task;
    _tasks.add(task);
    void check() {
      task.check();
      if (_disposed || !request.isCurrent()) {
        throw const ImageWorkTaskCancelled();
      }
    }

    try {
      onChanged();
      check();
      if (!request.supported) {
        onUnsupported();
        return;
      }
      final index = await task.select(select);
      check();
      if (index == null) return;
      final result = await request.toggle(index, check);
      check();
      onResult(result);
    } catch (failure, stack) {
      if (failure is! ImageWorkTaskCancelled) {
        if (_disposed || task.isCancelled || !request.isCurrent()) {
          task.recordFailure(failure, stack);
        } else {
          try {
            onError(failure, stack);
          } catch (reportError, reportStack) {
            task.recordFailure(failure, stack);
            task.recordFailure(reportError, reportStack);
          }
        }
      }
    } finally {
      if (identical(_collectTask, task)) _collectTask = null;
      _tasks.remove(task);
      task.finish();
      refresh();
    }
  }

  Future<void> dispose() {
    _disposed = true;
    _revision++;
    _removeResume();
    final tasks = _tasks.toList();
    for (final task in tasks) {
      task.cancel();
    }
    return Future.wait(tasks.map((task) => task.done)).then<void>((_) {});
  }
}
