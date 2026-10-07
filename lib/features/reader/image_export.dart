import 'dart:async';
import 'dart:typed_data';

import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'image_position.dart';

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
  ReaderImageAddress get address => ReaderImageAddress(
    imageKey: imageKey,
    sourceKey: sourceKey,
    comicId: comicId,
    chapterId: chapterId,
  );
  String get cacheKey => address.cacheKey;
}

/// Original content and export metadata, captured before opening a picker.
/// Once resolved, a selection stays independent of subsequent navigation.
class ReaderImageExportRequest {
  ReaderImageExportRequest({
    required List<String> images,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
    required this.title,
    required this.chapter,
    required this.isCurrent,
  }) : _images = List.unmodifiable(images);

  final List<String> _images;
  final String sourceKey;
  final String comicId;
  final String chapterId;
  final String title;
  final int chapter;
  final bool Function() isCurrent;

  ReaderImageSelection? resolve(int? index) {
    if (index == null || index < 0 || index >= _images.length || !isCurrent()) {
      return null;
    }
    return ReaderImageSelection(
      imageKey: _images[index],
      sourceKey: sourceKey,
      comicId: comicId,
      chapterId: chapterId,
      title: title,
      chapter: chapter,
      imageNumber: index + 1,
    );
  }
}

class ReaderImageExport {
  ReaderImageExport(
    ReaderImageSelection selection,
    this.bytes, {
    void Function()? checkStop,
  }) : _checkStop = checkStop,
       type = detectFileType(bytes),
       _stem =
           '${selection.title}_EP${selection.chapter}_P${selection.imageNumber}';
  final Uint8List bytes;
  final FileType type;
  final String _stem;
  final void Function()? _checkStop;
  String get filename => '$_stem${type.ext}';

  /// Recheck task admission after queuing/preparation, before native dispatch.
  /// An already-started native call still owns its original completion.
  void checkStop() => _checkStop?.call();
}

/// Selection, reading and platform delivery are adapters; identity is captured
/// before reading so navigation cannot rename an already selected image.
class ReaderImageExporter {
  ReaderImageExporter({
    required this.work,
    required this.select,
    required this.read,
    required this.save,
    required this.share,
    required this.onError,
    this.cancelSelection,
  });
  final ImageWork work;
  final Future<ReaderImageSelection?> Function() select;
  final Future<Uint8List> Function(ReaderImageSelection) read;
  final FutureOr<void> Function(ReaderImageExport) save;
  final FutureOr<void> Function(ReaderImageExport) share;
  final void Function(Object, StackTrace) onError;
  final void Function()? cancelSelection;
  final _tasks = <ImageWorkTask>{};
  bool _disposed = false;

  Future<void> export({required bool sharing}) async {
    if (_disposed) return;
    final request = work.start(cancelSelection: cancelSelection);
    if (request == null) return;
    _tasks.add(request);
    try {
      final selection = await request.select(select);
      if (selection == null) return;
      final bytes = await request.read(() => read(selection));
      request.check();
      final result = ReaderImageExport(
        selection,
        bytes,
        checkStop: request.check,
      );
      // Wait for the plugin's acknowledgment; on Windows this does not mean
      // the external receiver has finished reading the shared file.
      await (sharing ? share(result) : save(result));
    } catch (error, stack) {
      if (error is! ImageWorkTaskCancelled) {
        if (request.isCancelled || _disposed) {
          request.recordFailure(error, stack);
        } else {
          try {
            onError(error, stack);
          } catch (reportError, reportStack) {
            request.recordFailure(error, stack);
            request.recordFailure(reportError, reportStack);
          }
        }
      }
    } finally {
      _tasks.remove(request);
      request.finish();
    }
  }

  Future<void> dispose() {
    _disposed = true;
    final tasks = _tasks.toList();
    for (final task in tasks) {
      task.cancel();
    }
    return Future.wait(tasks.map((task) => task.done)).then<void>((_) {});
  }
}
