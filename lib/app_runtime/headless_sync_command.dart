import 'package:venera_next/foundation/res.dart';

/// Maps sync service outcomes to the existing CLI JSON/status convention.
/// The entrypoint owns process exit and application service lifetime.
Future<int> runHeadlessSyncCommand(
  String? command, {
  required bool isConfigured,
  required Future<Res<bool>> Function() upload,
  required Future<Res<bool>> Function() download,
  required void Function(Map<String, dynamic>) emit,
}) async {
  if (command != 'up' && command != 'down') {
    emit({
      'status': 'error',
      'message': 'Invalid webdav command. Use "up" or "down".',
    });
    return 1;
  }
  if (!isConfigured) {
    emit({'status': 'error', 'message': 'WebDAV sync is not configured.'});
    return 1;
  }
  final uploading = command == 'up';
  emit({
    'status': 'running',
    'message': uploading
        ? 'Uploading WebDAV data...'
        : 'Downloading WebDAV data...',
  });
  Res<bool> result;
  try {
    result = await (uploading ? upload() : download());
  } catch (error, stack) {
    result = Res.fromException(error, stack);
  }
  final operation = uploading ? 'Upload' : 'Download';
  emit({
    'status': result.error ? 'error' : 'success',
    'message': result.error
        ? '$operation failed: ${result.errorMessage}'
        : '$operation complete.',
  });
  return result.error ? 1 : 0;
}
