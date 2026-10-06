import 'package:venera_next/foundation/operation_failure.dart';

enum SourceMutationState { applied, recoveryRequired }

typedef SourceMutationError = ({String stage, Object error, StackTrace stack});

/// A successful rollback rethrows the original error. This result identifies
/// committed effects or incomplete recovery and preserves every stage failure.
class SourceMutationFailure implements FailureDetails {
  SourceMutationFailure({
    required this.state,
    required Iterable<SourceMutationError> failures,
    this.recoveryPath,
  }) : failures = List.unmodifiable(failures);
  final SourceMutationState state;
  final List<SourceMutationError> failures;
  final String? recoveryPath;
  @override
  FailureKind get kind => FailureKind.failed;
  @override
  Object get cause => failures.first.error;
  @override
  StackTrace get stackTrace => failures.first.stack;
  @override
  String get message =>
      '${state == SourceMutationState.applied ? 'Source change was applied' : 'Source recovery is incomplete'}: ${failures.map((failure) => '${failure.stage}: ${failure.error}').join('; ')}${recoveryPath == null ? '' : '; backup: $recoveryPath'}';
  @override
  String toString() => message;
}
