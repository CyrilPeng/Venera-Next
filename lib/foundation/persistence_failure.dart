import 'operation_failure.dart';

/// Only [notCommitted] permits replaying an incremental write. A failed
/// acknowledgement or cleanup must not be mistaken for a failed commit.
enum PersistenceCommitState { notCommitted, committed, unknown }

class PersistenceFailure implements FailureDetails {
  PersistenceFailure({
    required this.commitState,
    required this.cause,
    required this.stackTrace,
    Iterable<({Object error, StackTrace stackTrace})> cleanupFailures =
        const [],
  }) : cleanupFailures = List.unmodifiable(cleanupFailures);

  final PersistenceCommitState commitState;
  @override
  final Object cause;
  @override
  final StackTrace stackTrace;
  final List<({Object error, StackTrace stackTrace})> cleanupFailures;

  @override
  FailureKind get kind => FailureKind.failed;

  @override
  String get message =>
      'Persistence ${commitState.name}: $cause'
      '${cleanupFailures.isEmpty ? '' : '; cleanup: ${cleanupFailures.map((failure) => failure.error).join('; ')}'}';

  @override
  String toString() => message;
}
