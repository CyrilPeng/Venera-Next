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
  });

  final void Function(LocalComic) commitComic;
  final void Function() notifyChanged;
  final void Function() requestSave;

  // Mutable compatibility view; production mutations go through this service.
  final List<DownloadTask> tasks = [];
  final _completing = Set<DownloadTask>.identity();
  int _revision = 0;

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
    tasks.add(task);
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
      tasks.removeAt(index);
      final revision = ++_revision;
      _publish();
      _resumeIfUnchanged(revision);
    } finally {
      _completing.remove(task);
    }
  }

  void _resumeIfUnchanged(int revision) {
    // A nested queue operation owns the final scheduling decision.
    if (revision == _revision) tasks.firstOrNull?.resume();
  }

  void remove(DownloadTask task) {
    final index = _indexOf(task);
    if (index < 0) return;
    tasks.removeAt(index);
    _revision++;
    _publish();
  }

  void moveToFirst(DownloadTask task) {
    if (_indexOf(task) <= 0) return;
    final first = tasks.first;
    final shouldResume = !first.isPaused;
    final beforePause = _revision;
    first.pause();
    if (beforePause != _revision || !identical(tasks.firstOrNull, first)) {
      return;
    }
    final index = _indexOf(task);
    if (index <= 0) return;
    tasks.removeAt(index);
    tasks.insert(0, task);
    final revision = ++_revision;
    _publish();
    if (shouldResume) _resumeIfUnchanged(revision);
  }
}
