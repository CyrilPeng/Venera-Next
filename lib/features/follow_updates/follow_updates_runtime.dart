import 'package:flutter/foundation.dart';
import 'follow_update_task.dart';
import 'follow_updates_service.dart';

/// Owns one background checker and its external change subscription.
class FollowUpdatesRuntime {
  FollowUpdatesRuntime({
    required String? Function() folder,
    required bool Function() isChecking,
    required Future<void> Function() waitForDownload,
    required FollowUpdateTask Function(String) createTask,
    required void Function(Object, StackTrace) onError,
    required void Function() Function(void Function()) observeChanges,
  }) : _observeChanges = observeChanges {
    _service = FollowUpdatesService(
      folder: folder,
      isChecking: isChecking,
      waitForDownload: waitForDownload,
      createTask: createTask,
      onUpdated: notifyChanged,
      onError: onError,
    );
  }

  late final FollowUpdatesService _service;
  final void Function() Function(void Function()) _observeChanges;
  final _changes = ValueNotifier<int>(0);
  VoidCallback? _unsubscribe;
  bool _disposed = false;
  Future<void>? _closing;

  ValueListenable<int> get changes => _changes;
  bool get isRunning => _service.isRunning;

  void notifyChanged() {
    if (!_disposed) _changes.value++;
  }

  /// Subscription setup must be atomic and return its release callback.
  void start() {
    if (_disposed) throw StateError('Follow updates runtime is disposed');
    if (isRunning || _service.isPreparingForExit) return;
    try {
      // Exit restoration may have stopped scheduling while this runtime's
      // final-change subscription remained attached.
      _unsubscribe ??= _observeChanges(notifyChanged);
      _service.start();
    } catch (_) {
      stop();
      rethrow;
    }
  }

  void cancelChecking() => _service.cancelChecking();

  /// Keep the subscription alive for final changes from accepted tasks. The
  /// held service rejects new checks until the host releases its preparation.
  Future<VoidCallback> prepareForExit() {
    if (_disposed) {
      return Future.error(StateError('Follow updates runtime is disposed'));
    }
    return _service.prepareForExit();
  }

  void stop() {
    final unsubscribe = _unsubscribe;
    _unsubscribe = null;
    try {
      _service.stop();
    } finally {
      unsubscribe?.call();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      stop();
    } finally {
      _changes.dispose();
    }
  }

  Future<void> closeAndWait() {
    final closing = _closing;
    if (closing != null) return closing;
    Object? disposalError;
    StackTrace? disposalStack;
    try {
      dispose();
    } catch (error, stack) {
      disposalError = error;
      disposalStack = stack;
    }
    return _closing = _finishClose(disposalError, disposalStack);
  }

  Future<void> _finishClose(Object? error, StackTrace? stack) async {
    final failures = <({Object error, StackTrace stack})>[
      if (error != null) (error: error, stack: stack!),
    ];
    try {
      await _service.closeAndWait();
    } on FollowUpdatesCloseFailure catch (error) {
      failures.addAll(error.failures);
    } catch (error, stack) {
      failures.add((error: error, stack: stack));
    }
    if (failures.isNotEmpty) throw FollowUpdatesCloseFailure(failures);
  }
}
