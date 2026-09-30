import 'dart:async';

import 'package:flutter/foundation.dart';

enum InitializationState { notStarted, initializing, ready, failed }

/// One explicit initialization attempt, shared by all callers and waiters.
abstract mixin class Init {
  InitializationState _initializationState = InitializationState.notStarted;
  Completer<void>? _attempt;

  InitializationState get initializationState => _initializationState;

  /// Wait for explicit [init] without starting dependency work implicitly.
  /// A failed attempt remains failed until its owner calls [retryInit].
  Future<void> ensureInit() => (_attempt ??= Completer<void>()).future;

  @protected
  Future<void> doInit();

  /// Concurrent calls share one execution, including its error and stack trace.
  Future<void> init() {
    final result = ensureInit();
    if (_initializationState != InitializationState.notStarted) return result;
    _initializationState = InitializationState.initializing;
    final attempt = _attempt!;
    Future<void>.sync(doInit).then(
      (_) {
        _initializationState = InitializationState.ready;
        attempt.complete();
      },
      onError: (Object error, StackTrace stack) {
        _initializationState = InitializationState.failed;
        attempt.completeError(error, stack);
      },
    );
    return result;
  }

  /// Explicitly start a new attempt after failure. Active/ready work is reused.
  /// Implementations must clean up partially initialized resources on failure.
  Future<void> retryInit() {
    if (_initializationState == InitializationState.failed) {
      _attempt = null;
      _initializationState = InitializationState.notStarted;
    }
    return init();
  }
}
