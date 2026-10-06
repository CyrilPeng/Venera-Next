import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:venera_next/network/request_scope.dart';

import 'file_type.dart';
import 'image_work.dart';

/// Owns complete image-save operations, including reads whose page has gone.
/// The caller captures the image and name before handing over the operation.
class ImageSaveWork {
  ImageSaveWork({required this.deliver, required this.onError});

  final Future<bool> Function(
    Uint8List bytes,
    String filename,
    void Function() checkStop,
  )
  deliver;
  final void Function(Object error, StackTrace stack) onError;
  final _work = ImageWork();
  final _tasks = <ImageWorkTask>{};
  final _retainedTasks =
      <
        ImageWorkTask,
        ({void Function() release, _ImageSaveTaskBinding binding})
      >{};
  _ImageSaveTaskBinding? _binding;
  final _listeners = <void Function()>{};
  bool _disposed = false;

  bool get isBusy => _tasks.isNotEmpty;

  /// New tasks capture this binding before listeners or reads execute. Detach
  /// cancels only its accepted tasks, whose original owners keep their drains.
  void Function() bindTasks({
    required bool Function() canStart,
    required void Function() Function(ImageWorkTask) retain,
  }) {
    if (_binding != null) throw StateError('Image saves are already bound');
    final binding = _ImageSaveTaskBinding(canStart, retain);
    _binding = binding;
    for (final task in _tasks.toList()) {
      if (!_retainedTasks.containsKey(task)) _retainTask(task, binding);
    }
    return () {
      if (!identical(_binding, binding)) return;
      _binding = null;
      for (final task in binding.tasks.toList()) {
        task.cancel();
      }
    };
  }

  void _retainTask(ImageWorkTask task, _ImageSaveTaskBinding binding) {
    binding.tasks.add(task);
    if (!binding.canStart()) task.cancel();
    try {
      final release = binding.retain(task);
      _retainedTasks[task] = (release: release, binding: binding);
    } catch (_) {
      binding.tasks.remove(task);
      rethrow;
    }
  }

  void Function() addListener(void Function() listener) {
    if (_disposed) return () {};
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _notify(ImageWorkTask task) {
    for (final listener in _listeners.toList()) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (error, stack) {
        task.recordFailure(error, stack);
      }
    }
  }

  Future<bool> save({
    required Future<Uint8List> Function(RequestScope scope) read,
    required String name,
  }) async {
    if (_disposed || _binding?.canStart() == false) return false;
    final scope = RequestScope();
    final task = _work.start(onCancel: scope.cancel);
    if (task == null) {
      scope.dispose();
      return false;
    }
    _tasks.add(task);
    try {
      final binding = _binding;
      if (binding != null) _retainTask(task, binding);
      _notify(task);
      task.check();
      final bytes = await scope.runToCompletion(() => read(scope));
      task.check();
      final filename = '$name${detectFileType(bytes).ext}';
      // The adapter checks again after queuing/source preparation, before it
      // opens a native dialog. Already-started delivery and cleanup still join.
      return await deliver(bytes, filename, task.check);
    } catch (error, stack) {
      final cancelled =
          error is RequestCancelled ||
          error is ImageWorkTaskCancelled ||
          (error is DioException && CancelToken.isCancel(error));
      if (!cancelled) {
        if (task.isCancelled || _disposed) {
          task.recordFailure(error, stack);
        } else {
          try {
            onError(error, stack);
          } catch (reportError, reportStack) {
            task.recordFailure(error, stack);
            task.recordFailure(reportError, reportStack);
          }
        }
      }
      return false;
    } finally {
      scope.dispose();
      _tasks.remove(task);
      task.finish();
      _notify(task);
      final retained = _retainedTasks.remove(task);
      retained?.binding.tasks.remove(task);
      if (!task.hasFailures) retained?.release();
    }
  }

  void Function() holdForExit() => _work.holdForExit();

  Future<void Function()> prepareForExit() => _work.prepareForExit();

  Future<void> dispose() {
    _disposed = true;
    _listeners.clear();
    return _work.dispose();
  }
}

class _ImageSaveTaskBinding {
  _ImageSaveTaskBinding(this.canStart, this.retain);
  final bool Function() canStart;
  final void Function() Function(ImageWorkTask) retain;
  final tasks = <ImageWorkTask>{};
}
