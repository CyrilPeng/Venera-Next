import 'dart:async';
import 'dart:typed_data';

import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/network/request_scope.dart';

class ReaderImageSelection {
  const ReaderImageSelection({
    required this.imageKey,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
    required this.title,
    required this.chapter,
    required this.imageNumber,
  });
  final String imageKey;
  final String sourceKey;
  final String comicId;
  final String chapterId;
  final String title;
  final int chapter;
  final int imageNumber;
  String get cacheKey => '$imageKey@$sourceKey@$comicId@$chapterId';
}

class ReaderImageExport {
  ReaderImageExport(ReaderImageSelection selection, this.bytes)
    : type = detectFileType(bytes),
      _stem =
          '${selection.title}_EP${selection.chapter}_P${selection.imageNumber}';
  final Uint8List bytes;
  final FileType type;
  final String _stem;
  String get filename => '$_stem${type.ext}';
}

/// Selection, reading and platform delivery are adapters; identity is captured
/// before reading so navigation cannot rename an already selected image.
class ReaderImageExporter {
  ReaderImageExporter({
    required this.select,
    required this.read,
    required this.save,
    required this.share,
    required this.onError,
  });
  final Future<ReaderImageSelection?> Function() select;
  final Future<Uint8List> Function(ReaderImageSelection) read;
  final FutureOr<void> Function(ReaderImageExport) save;
  final FutureOr<void> Function(ReaderImageExport) share;
  final void Function(Object, StackTrace) onError;
  final _lifetime = RequestScope();

  Future<void> export({required bool sharing}) async {
    if (_lifetime.isCancelled) return;
    final request = RequestScope(parent: _lifetime);
    try {
      final selection = await request.run(select);
      if (selection == null) return;
      final bytes = await request.run(() => read(selection));
      request.check();
      final result = ReaderImageExport(selection, bytes);
      // Once handed to the platform, its dialog/share sheet owns completion.
      await (sharing ? share(result) : save(result));
    } catch (error, stack) {
      if (!request.isCancelled) onError(error, stack);
    } finally {
      request.dispose();
    }
  }

  void dispose() {
    _lifetime.cancel();
    _lifetime.dispose();
  }
}
