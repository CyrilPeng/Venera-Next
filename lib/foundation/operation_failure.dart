enum FailureKind { failed, cancelled, unsupported }

/// Structured diagnostics independent of transport, UI and feature domains.
abstract interface class FailureDetails implements Exception {
  FailureKind get kind;
  String get message;
  Object? get cause;
  StackTrace? get stackTrace;
}

class OperationFailure implements FailureDetails {
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
