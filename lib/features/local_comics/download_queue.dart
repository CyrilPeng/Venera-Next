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
    _publish();
    tasks.firstOrNull?.resume();
  }

  void complete(DownloadTask task) {
    final index = _indexOf(task);
    if (index < 0) return;
    // A failed commit leaves the resumable task in place, with no notification
    // or snapshot update. Only the exact queued instance may complete work.
    commitComic(task.toLocalComic());
    tasks.removeAt(index);
    _publish();
    tasks.firstOrNull?.resume();
  }

  void remove(DownloadTask task) {
    final index = _indexOf(task);
    if (index < 0) return;
    tasks.removeAt(index);
    _publish();
  }

  void moveToFirst(DownloadTask task) {
    final index = _indexOf(task);
    if (index <= 0) return;
    final shouldResume = !tasks.first.isPaused;
    tasks.first.pause();
    tasks.removeAt(index);
    tasks.insert(0, task);
    _publish();
    if (shouldResume) tasks.firstOrNull?.resume();
  }
}
