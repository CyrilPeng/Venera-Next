import 'dart:convert';
import 'dart:io';

/// JSON snapshots for resumable downloads. The manager supplies paths and task
/// codecs; this store has no dependency on running tasks or application globals.
class DownloadTaskStore {
  DownloadTaskStore({required this.onError});

  final void Function(Object, StackTrace) onError;
  Future<void> _writes = Future.value();

  Future<void> get pendingWrites => _writes;

  Future<void> save(String path, Iterable<Map<String, dynamic>> tasks) {
    // Serialize before yielding, including nested mutable task state.
    final snapshot = jsonEncode(tasks.toList());
    final write = _writes.then((_) => _replace(path, snapshot));
    _writes = write.then<void>((_) {}, onError: onError);
    return write;
  }

  Future<void> _replace(String path, String snapshot) async {
    final target = File(path);
    // Stage on the same filesystem, without truncating the last saved snapshot.
    final staging = await target.parent.createTemp('.download-tasks-');
    try {
      final file = File('${staging.path}/snapshot.json');
      await file.writeAsString(snapshot, flush: true);
      await file.rename(target.path);
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (error, stack) {
        onError(error, stack);
      }
    }
  }

  /// Decode completely before the manager publishes a new queue. A missing
  /// snapshot leaves the queue unchanged; invalid data is retained for recovery.
  List<T>? restore<T>(String path, T? Function(Map<String, dynamic>) decode) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final data = jsonDecode(file.readAsStringSync());
    if (data is! List) {
      throw const FormatException('Download task snapshot must be a list');
    }
    final tasks = <T>[];
    for (final entry in data) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Download task entry must be an object');
      }
      final task = decode(entry);
      if (task != null) tasks.add(task);
    }
    return tasks;
  }
}
