import 'package:venera_next/foundation/operation_failure.dart';

/// A failed follow-up step cannot undo an already established commit.
/// [recoveryRequired] means a remote acknowledgement or local rollback cannot
/// establish a safe outcome for another transfer.
enum DataSyncCommitState { notApplied, applied, recoveryRequired }

/// A persisted commit time must be representable by DateTime and nonnegative.
bool isValidDataSyncCommitTime(Object? value) =>
    value is int && value >= 0 && value <= 8640000000000000;

typedef DataSyncDiagnostic = ({String stage, Object error, StackTrace stack});

/// Sync/import diagnostics retain commit evidence independently of presentation.
class DataSyncFailure implements FailureDetails {
  DataSyncFailure({
    required this.commitState,
    required Iterable<DataSyncDiagnostic> failures,
    this.recoveryPath,
  }) : failures = List.unmodifiable(failures);

  final DataSyncCommitState commitState;
  final List<DataSyncDiagnostic> failures;
  final String? recoveryPath;

  @override
  FailureKind get kind => FailureKind.failed;

  @override
  Object? get cause => failures.firstOrNull?.error;

  @override
  StackTrace? get stackTrace => failures.firstOrNull?.stack;

  @override
  String get message => failures
      .map((failure) => '${failure.stage}: ${failure.error}')
      .join('; ');

  @override
  String toString() => message;
}

/// Only the import's unfinished post-commit cleanup is resumable. Re-entering
/// this continuation must not extract or apply the archive again.
class DataSyncImportFailure extends DataSyncFailure {
  DataSyncImportFailure({
    required super.commitState,
    required super.failures,
    super.recoveryPath,
    this.resume,
  });

  final Future<DataSyncCommitState> Function()? resume;
}
