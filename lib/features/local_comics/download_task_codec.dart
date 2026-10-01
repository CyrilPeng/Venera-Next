import 'download_task.dart';
import 'images_download_task.dart';

/// Decode the persisted task kinds supported by the existing restore protocol.
DownloadTask? downloadTaskFromJson(Map<String, dynamic> json) {
  switch (json['type']) {
    case 'ImagesDownloadTask':
      return ImagesDownloadTask.fromJson(json);
    default:
      return null;
  }
}
