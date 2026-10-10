enum FailureKind { failed, cancelled, unsupported }

/// Structured diagnostics independent of transport, UI and feature domains.
abstract interface class FailureDetails implements Exception {
  FailureKind get kind;
  String get message;
  Object? get cause;
  StackTrace? get stackTrace;
}

class OperationFailure implements FailureDetails {
  /// Capture a locally detected failure without losing its original display
  /// message when it crosses a result, parser, or platform boundary.
  OperationFailure.message(this.message, {this.kind = FailureKind.failed})
    : cause = null,
      stackTrace = StackTrace.current;

  const OperationFailure({
    required this.message,
    this.kind = FailureKind.failed,
    this.cause,
    this.stackTrace,
  });

  @override
  final FailureKind kind;
  @override
  final String message;
  @override
  final Object? cause;
  @override
  final StackTrace? stackTrace;

  @override
  String toString() => message;
}
