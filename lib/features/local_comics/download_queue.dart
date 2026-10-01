import 'dart:collection';
import 'dart:async';
import 'package:venera_next/foundation/comic_type.dart';
import 'download_task.dart';
import 'local_comic_model.dart';

/// Ordered task coordination, independent of global managers and concrete
/// download implementations. Storage/notification adapters are supplied by owner.
class DownloadQueue {
  DownloadQueue({
    required this.commitComic,
    required this.notifyChanged,
    required this.requestSave,
    required this.reportError,
  });

  final void Function(LocalComic) commitComic;
  final void Function() notifyChanged;
  final void Function() requestSave;
  final void Function(Object, StackTrace) reportError;
  Future<void>? _pendingStop;
  int? _scheduledResumeRevision;

  final List<DownloadTask> _tasks = [];
  late final List<DownloadTask> tasks = UnmodifiableListView(_tasks);
  final _completing = Set<DownloadTask>.identity();
  int _revision = 0;

  /// Publish a complete paused snapshot during initialization/recovery, without
  /// starting tasks, notifying listeners or writing the snapshot back to disk.
  void restorePausedTasks(Iterable<DownloadTask> restored) {
    final revision = _revision;
    final snapshot = <DownloadTask>[];
    final identities = <(String, int)>{};
    for (final task in restored) {
      if (!task.isPaused) throw StateError('Cannot restore a running task');
      if (identities.add((task.id, task.comicType.value))) snapshot.add(task);
    }
    if (_pendingStop != null ||
        revision != _revision ||
        _completing.isNotEmpty ||
        _tasks.any((task) => !task.isPaused)) {
      throw StateError('Cannot replace an active or changed download queue');
    }
    _tasks
      ..clear()
      ..addAll(snapshot);
    _revision++;
  }

  bool contains(String id, ComicType type) =>
      tasks.any((task) => task.id == id && task.comicType == type);

  int _indexOf(DownloadTask task) =>
      tasks.indexWhere((current) => identical(current, task));

  void _publish() {
    notifyChanged();
    requestSave();
  }

  void add(DownloadTask task) {
    if (contains(task.id, task.comicType)) return;
    _tasks.add(task);
    final revision = ++_revision;
    _publish();
    _resumeIfUnchanged(revision);
  }

  void complete(DownloadTask task) {
    if (_indexOf(task) < 0 || !_completing.add(task)) return;
    try {
      final comic = task.toLocalComic();
      if (_indexOf(task) < 0) return;
      // Commit adapters and task methods may synchronously reenter the queue.
      // Never reuse an index captured before calling them.
      commitComic(comic);
      final index = _indexOf(task);
      if (index < 0) return;
      _tasks.removeAt(index);
      final revision = ++_revision;
      _publish();
      _resumeIfUnchanged(revision);
    } finally {
      _completing.remove(task);
    }
  }

  void _resumeIfUnchanged(int revision) {
    // A nested queue operation owns the final scheduling decision.
    if (revision != _revision) return;
    final stop = _pendingStop;
    if (stop == null) {
      _scheduledResumeRevision = null;
      tasks.firstOrNull?.resume();
    } else {
      _scheduledResumeRevision = revision;
      unawaited(
        stop
            .then<void>(
              (_) => _resumeIfUnchanged(revision),
              onError: (Object error, StackTrace stack) {},
            )
            .catchError(reportError),
      );
    }
  }

  void remove(DownloadTask task) {
    final index = _indexOf(task);
    if (index < 0) return;
    _tasks.removeAt(index);
    _revision++;
    _publish();
  }

  Future<void> moveToFirst(DownloadTask task) {
    if (_indexOf(task) <= 0) return Future.value();
    final first = tasks.first;
    final shouldResume =
        !first.isPaused || _scheduledResumeRevision == _revision;
    final beforePause = _revision;
    final stopped = _pauseBeforeScheduling(first);
    if (beforePause != _revision || !identical(tasks.firstOrNull, first)) {
      return stopped;
    }
    final index = _indexOf(task);
    if (index <= 0) return stopped;
    _tasks.removeAt(index);
    _tasks.insert(0, task);
    final revision = ++_revision;
    _publish();
    if (shouldResume) _resumeIfUnchanged(revision);
    return stopped;
  }

  Future<void> _pauseBeforeScheduling(DownloadTask task) {
    final previous = _pendingStop;
    final gate = Completer<void>();
    final stopped = _pendingStop = gate.future;
    // UI callers may ignore the result; failures are also sent to the owner.
    stopped.ignore();
    void finish([Object? error, StackTrace? stack]) {
      if (identical(_pendingStop, stopped)) _pendingStop = null;
      if (error == null) {
        gate.complete();
      } else {
        gate.completeError(error, stack);
        reportError(error, stack!);
      }
    }

    // Install the barrier before pause can notify/reenter queue operations.
    try {
      task.pause();
      unawaited(
        Future.wait<void>([?previous, task.pendingCleanup]).then<void>(
          (_) => finish(),
          onError: (Object error, StackTrace stack) => finish(error, stack),
        ),
      );
    } catch (error, stack) {
      scheduleMicrotask(() => finish(error, stack));
    }
    return stopped;
  }
}
