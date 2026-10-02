import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera_next/foundation/file_interaction.dart';

import 'document_import.dart';
import 'pdf_import_batch.dart';

/// A task belongs to the application, not to the dialog displaying it.
class PdfImportTask extends ChangeNotifier {
  PdfImportTask._(List<FileSelection> files, PdfImportBatch batch)
    : _files = List.of(files),
      _batch = batch,
      fileCount = files.length,
      name = files.first.name;

  final String name;
  final int fileCount;
  List<FileSelection> _files;
  PdfImportBatch? _batch;
  final _cancellation = DocumentImportCancellation();
  final _done = Completer<PdfImportBatchResult>();
  bool _started = false;
  PdfImportBatchProgress? _progress;
  PdfImportBatchResult? _result;

  bool get isQueued => !_started;
  bool get isFinished => _result != null;
  bool get isCancelling => _cancellation.isCancelled && !isFinished;
  PdfImportBatchProgress? get progress => _progress;
  PdfImportBatchResult? get result => _result;
  Future<PdfImportBatchResult> get done => _done.future;

  void _changed() => notifyListeners();
}

/// Serializes PDF conversion across batches to bound memory use and avoid
/// competing title checks. Tasks and results last until the app exits.
class PdfImportTasks extends ChangeNotifier {
  static final instance = PdfImportTasks();

  final _tasks = <PdfImportTask>[];
  PdfImportTask? _active;
  Future<VoidCallback>? _exitPreparation;

  List<PdfImportTask> get tasks => List.unmodifiable(_tasks);
  int get activeCount => _tasks.where((task) => !task.isFinished).length;

  PdfImportTask add({
    required List<FileSelection> files,
    required PdfImportBatch batch,
  }) {
    if (_exitPreparation != null) {
      throw StateError('PDF imports are suspended for exit');
    }
    if (files.isEmpty) throw ArgumentError.value(files, 'files', 'Empty batch');
    final task = PdfImportTask._(files, batch);
    task.addListener(notifyListeners);
    _tasks.add(task);
    notifyListeners();
    _startNext();
    return task;
  }

  void cancel(PdfImportTask task) {
    if (!_tasks.contains(task) || task.isFinished || task.isCancelling) return;
    task._cancellation.cancel();
    task._changed();
    if (task.isQueued) {
      // Release queued selections immediately, without preparing or converting
      // them, even while another batch is still processing a page.
      task._started = true;
      unawaited(_run(task));
    }
  }

  void clearFinished() {
    for (final task in _tasks.where((task) => task.isFinished).toList()) {
      task.removeListener(notifyListeners);
      _tasks.remove(task);
    }
    notifyListeners();
  }

  void _startNext() {
    if (_active != null || _exitPreparation != null) return;
    for (final task in _tasks) {
      if (task._started) continue;
      _active = task;
      task._started = true;
      task._changed();
      unawaited(_run(task));
      return;
    }
  }

  /// Cancel uncommitted work and drain conversion/selection cleanup before exit.
  /// The returned release permits new batches if the window remains open.
  Future<VoidCallback> prepareForExit() {
    final existing = _exitPreparation;
    if (existing != null) return existing;
    final ready = Completer<VoidCallback>();
    final preparation = _exitPreparation = ready.future;
    final pending = _tasks.where((task) => !task.isFinished).toList();
    for (final task in pending) {
      cancel(task);
    }
    Future.wait(pending.map((task) => task.done)).then(
      (_) => ready.complete(() {
        if (identical(_exitPreparation, preparation)) _exitPreparation = null;
      }),
      onError: (Object error, StackTrace stack) {
        if (identical(_exitPreparation, preparation)) _exitPreparation = null;
        ready.completeError(error, stack);
      },
    );
    return preparation;
  }

  Future<void> _run(PdfImportTask task) async {
    final result = await task._batch!.run(
      task._files,
      cancellation: task._cancellation,
      onProgress: (progress) {
        task._progress = progress;
        task._changed();
      },
    );
    // FileSelection.dispose is handled by the batch, including cancellation.
    // Retain only the summary, not file handles or the import closure.
    task._files = const [];
    task._batch = null;
    task._result = result;
    task._done.complete(result);
    task._changed();
    if (identical(_active, task)) {
      _active = null;
      _startNext();
    }
  }

  @override
  void dispose() {
    for (final task in _tasks) {
      task.removeListener(notifyListeners);
    }
    super.dispose();
  }
}
