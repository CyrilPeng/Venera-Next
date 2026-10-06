import 'package:venera_next/foundation/operation_failure.dart';

/// Stable source-management reasons; presentation chooses when to translate.
enum SourceFailureCode {
  invalidUrl('Enter a complete HTTP or HTTPS URL.'),
  unavailableRepository('Unable to load repository.'),
  invalidCatalog('The address must return a source list in JSON format.'),
  invalidImport('Expected a source script (JS) or a source list (JSON).'),
  emptyCatalog('The repository contains no usable source entries.'),
  missingName('Enter a repository name.'),
  duplicateRepository('This repository address has already been added.'),
  missingRepository('Repository no longer exists.'),
  repositoryChanged('Repository changed. Refresh the list and try again.'),
  missingSource('This source is no longer listed in its repository.'),
  ambiguousSource(
    'Multiple variants found. Choose a source in the repository again.',
  ),
  updateInProgress('Update already in progress'),
  cancelled('Source update cancelled.');

  const SourceFailureCode(this.message);
  final String message;
}

class SourceFailure implements FailureDetails {
  const SourceFailure(this.code, {this.cause, this.stackTrace});
  final SourceFailureCode code;
  @override
  final Object? cause;
  @override
  final StackTrace? stackTrace;

  @override
  String get message => code.message;

  @override
  FailureKind get kind => code == SourceFailureCode.cancelled
      ? FailureKind.cancelled
      : FailureKind.failed;

  @override
  String toString() => code.message;
}

/// Preserve the original failure and its scope until the output boundary.
class SourceCheckFailure {
  const SourceCheckFailure(this.cause, {this.repository, this.source});
  final Object cause;
  final String? repository;
  final String? source;

  String format(String Function(Object) describe) {
    final scope = [repository, source].whereType<String>().join(' / ');
    return scope.isEmpty ? describe(cause) : '$scope: ${describe(cause)}';
  }

  @override
  String toString() => format((cause) => cause.toString());
}
