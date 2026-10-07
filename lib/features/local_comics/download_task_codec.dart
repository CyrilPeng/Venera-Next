import 'download_task.dart';
import 'download_task_storage.dart';
import 'images_download_task.dart';

/// Decode the persisted task kinds supported by the existing restore protocol.
DownloadTask? downloadTaskFromJson(
  Map<String, dynamic> json, {
  required DownloadTaskStorage storage,
}) {
  switch (json['type']) {
    case 'ImagesDownloadTask':
      return ImagesDownloadTask.fromJson(storage, json);
    default:
      return null;
  }
}
