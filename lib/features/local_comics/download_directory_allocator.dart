import 'package:venera_next/foundation/comic_type.dart';
import 'package:venera_next/foundation/file_system.dart';

class DownloadDirectoryAllocation {
  const DownloadDirectoryAllocation(this.directory, {required this.isNew});

  final Directory directory;
  final bool isNew;
}

/// Serializes download directory selection and creation for one library owner.
/// Existing empty directories are occupied too: another task may own them.
class DownloadDirectoryAllocator {
  DownloadDirectoryAllocator({
    required this.rootPath,
    required this.findRegisteredPath,
  });

  final String Function() rootPath;
  final String? Function(String, ComicType) findRegisteredPath;
  Future<void> _pending = Future.value();

  Future<DownloadDirectoryAllocation> allocate(
    String id,
    ComicType type,
    String title,
  ) {
    final allocation = _pending.then((_) => _allocate(id, type, title));
    // A failed allocation must not prevent later requests from retrying.
    _pending = allocation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return allocation;
  }

  Future<DownloadDirectoryAllocation> _allocate(
    String id,
    ComicType type,
    String title,
  ) async {
    final registered = findRegisteredPath(id, type);
    if (registered != null) {
      return DownloadDirectoryAllocation(Directory(registered), isNew: false);
    }
    const maxTitleLength = 80;
    final name = title.length > maxTitleLength
        ? title.substring(0, maxTitleLength)
        : title;
    final root = rootPath();
    for (var suffix = 0; ; suffix++) {
      final candidate = FilePath.join(
        root,
        sanitizeFileName(suffix == 0 ? name : '$name($suffix)'),
      );
      if (Directory(candidate).existsSync() ||
          File(candidate).existsSync() ||
          Link(candidate).existsSync()) {
        continue;
      }
      final directory = await Directory(candidate).create();
      return DownloadDirectoryAllocation(directory, isNew: true);
    }
  }
}
