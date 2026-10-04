import 'dart:async';

import 'package:flutter/foundation.dart';

/// A stopped image attempt is expected and must not enter network retries.
class ImageProviderLoadCancelled implements Exception {
  const ImageProviderLoadCancelled();
}

class ImageProviderPreparationFailure implements Exception {
  ImageProviderPreparationFailure(
    Iterable<({Object error, StackTrace stack})> failures,
  ) : failures = List.unmodifiable(failures);

  final List<({Object error, StackTrace stack})> failures;

  @override
  String toString() =>
      'Image provider preparation failed: '
      '${failures.map((failure) => failure.error).join('; ')}';
}

/// Admission and actual attempt completion are separate from a Flutter image
/// stream, which can remain subscribed while shutdown is prepared or undone.
class ImageProviderLifecycle {
  final _holds = <Object>{};
  final _active = <ImageProviderLoadAttempt>{};
  final _cleanupFailures = <({Object error, StackTrace stack})>[];
  final _listeners = <({VoidCallback hold, VoidCallback resume})>{};
  Completer<void>? _resumed;

  bool get isHeld => _holds.isNotEmpty;

  VoidCallback listen({
    required VoidCallback hold,
    required VoidCallback resume,
  }) {
    final listener = (hold: hold, resume: resume);
    _listeners.add(listener);
    if (isHeld) hold();
    return () => _listeners.remove(listener);
  }

  int get activeCount => _active.length;

  void recordCleanupFailure(Object error, StackTrace stack) {
    _cleanupFailures.add((error: error, stack: stack));
  }

  /// A local owner has joined and received this cleanup failure. Do not replay
  /// the same buffered failure at a later, unrelated window preparation.
  void consumeCleanupFailure(Object error, StackTrace stack) {
    final index = _cleanupFailures.indexWhere(
      (failure) =>
          identical(failure.error, error) && identical(failure.stack, stack),
    );
    if (index >= 0) _cleanupFailures.removeAt(index);
  }

  Future<void> waitUntilReady({
    required Future<void> consumerCancelled,
    required bool Function() isConsumerCancelled,
  }) async {
    while (_holds.isNotEmpty && !isConsumerCancelled()) {
      await Future.any([_resumed!.future, consumerCancelled]);
    }
    if (isConsumerCancelled()) throw const ImageProviderLoadCancelled();
  }

  ImageProviderLoadAttempt? tryBegin() {
    if (_holds.isNotEmpty) return null;
    final attempt = ImageProviderLoadAttempt._(this);
    _active.add(attempt);
    return attempt;
  }

  /// Hold admission synchronously, then wait for every accepted attempt's real
  /// finally block. A failed preparation releases only its own hold.
  Future<VoidCallback> prepareForExit() {
    final hold = Object();
    if (_holds.isEmpty) _resumed = Completer<void>();
    _holds.add(hold);
    final failures = [..._cleanupFailures];
    _cleanupFailures.clear();
    for (final listener in _listeners.toList()) {
      try {
        listener.hold();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
    }
    final attempts = _active.toList();
    for (final attempt in attempts) {
      attempt._observedByPreparation = true;
      attempt.cancel();
    }
    void release() {
      if (!_holds.remove(hold) || _holds.isNotEmpty) return;
      final resumed = _resumed;
      _resumed = null;
      resumed?.complete();
      final failures = <({Object error, StackTrace stack})>[];
      for (final listener in _listeners.toList()) {
        try {
          listener.resume();
        } catch (error, stack) {
          failures.add((error: error, stack: stack));
        }
      }
      if (failures.isNotEmpty) throw ImageProviderPreparationFailure(failures);
    }

    return _prepare(attempts, release, failures);
  }

  Future<VoidCallback> _prepare(
    List<ImageProviderLoadAttempt> attempts,
    VoidCallback release,
    List<({Object error, StackTrace stack})> failures,
  ) async {
    await Future.wait([
      for (final attempt in attempts)
        attempt.done.catchError((Object error, StackTrace stack) {
          failures.add((error: error, stack: stack));
        }),
    ]);
    if (failures.isNotEmpty) {
      try {
        release();
      } catch (error, stack) {
        failures.add((error: error, stack: stack));
      }
      throw ImageProviderPreparationFailure(failures);
    }
    return release;
  }
}

class ImageProviderLoadAttempt {
  ImageProviderLoadAttempt._(this._owner) {
    _done.future.ignore();
  }

  final ImageProviderLifecycle _owner;
  final _cancelled = Completer<void>();
  final _done = Completer<void>();
  bool _observedByPreparation = false;
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  Future<void> get done => _done.future;

  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const ImageProviderLoadCancelled();
  }

  void finish({Object? error, StackTrace? stack}) {
    if (_done.isCompleted) return;
    _owner._active.remove(this);
    if (error != null) {
      if (!_observedByPreparation) {
        _owner.recordCleanupFailure(error, stack ?? StackTrace.current);
      }
      _done.completeError(error, stack);
    } else {
      _done.complete();
    }
  }
}
