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
  final _listeners = <void Function()>{};
  bool _disposed = false;

  bool get isBusy => _tasks.isNotEmpty;

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
    if (_disposed) return false;
    final scope = RequestScope();
    final task = _work.start(onCancel: scope.cancel);
    if (task == null) {
      scope.dispose();
      return false;
    }
    _tasks.add(task);
    try {
      _notify(task);
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
