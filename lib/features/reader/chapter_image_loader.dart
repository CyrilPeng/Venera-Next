import 'dart:io';

import 'package:venera_next/network/request_scope.dart';

/// Chapter loading policy with chapter-specific storage and source access.
/// The callbacks are resolved by the adapter, not by global manager lookups.
class ChapterImageLoader {
  const ChapterImageLoader({
    required this.readLocal,
    required this.loadOnline,
    required this.localPath,
    required this.onLocalFailure,
    required this.localUnavailable,
    required this.sourceUnavailable,
  });

  final Future<List<String>> Function()? readLocal;
  final Future<List<String>> Function()? loadOnline;
  final String localPath;
  final void Function(FileSystemException, StackTrace) onLocalFailure;
  final Object Function(String path) localUnavailable;
  final Object sourceUnavailable;

  Future<List<String>> load({
    RequestScope? scope,
    void Function()? onOnlineFallback,
  }) async {
    final request = RequestScope(parent: scope);
    try {
      return await request.run(() => _load(request, onOnlineFallback));
    } finally {
      request.dispose();
    }
  }

  Future<List<String>> _load(
    RequestScope scope,
    void Function()? onOnlineFallback,
  ) async {
    var missingLocal = false;
    if (readLocal != null) {
      try {
        final images = await readLocal!();
        scope.check();
        if (images.isEmpty) {
          throw FileSystemException('No local comic images found', localPath);
        }
        return images;
      } on FileSystemException catch (error, stack) {
        scope.check();
        onLocalFailure(error, stack);
        if (loadOnline == null) throw localUnavailable(error.path ?? localPath);
        missingLocal = true;
      }
    }
    scope.check();
    if (loadOnline == null) throw sourceUnavailable;
    final images = await loadOnline!();
    scope.check();
    if (missingLocal) onOnlineFallback?.call();
    return images;
  }
}
