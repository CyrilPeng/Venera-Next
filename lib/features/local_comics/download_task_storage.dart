import 'package:venera_next/foundation/comic_type.dart';

import 'download_directory_allocator.dart';
import 'download_task.dart';
import 'local_comic_model.dart';

/// The library that accepted a download owns its output and queue for its
/// entire lifetime, including restored tasks and asynchronous cleanup.
abstract interface class DownloadTaskStorage {
  String get path;

  LocalComic? find(String id, ComicType type);

  Future<DownloadDirectoryAllocation> allocateDownloadDirectory(
    String id,
    ComicType type,
    String name,
  );

  Future<void> saveCurrentDownloadingTasks();

  void completeTask(DownloadTask task);

  void removeTask(DownloadTask task);
}
