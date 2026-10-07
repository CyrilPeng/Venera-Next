import 'package:venera_next/features/local_comics/local_comic_model.dart';
import 'package:venera_next/foundation/file_system.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

/// Owns a newly created conversion directory until it is handed to its caller
/// or registration begins. Only a confirmed non-commit permits discarding it.
class ComicImportOutput {
  ComicImportOutput(this.directory);

  final Directory directory;
  PersistenceCommitState _commitState = PersistenceCommitState.notCommitted;
  bool _registrationStarted = false;

  PersistenceCommitState get commitState => _commitState;

  /// A failing registrar must report PersistenceCommitState.notCommitted to confirm
  /// that no records reference this output. An unclassified error is unknown.
  Future<void> register(
    LocalComic comic,
    Future<void> Function(LocalComic comic)? registrar,
  ) async {
    if (_registrationStarted) {
      throw StateError('Comic output registration has already started');
    }
    _registrationStarted = true;
    _commitState = PersistenceCommitState.unknown;
    try {
      await registrar?.call(comic);
      _commitState = PersistenceCommitState.committed;
    } on PersistenceFailure catch (error) {
      _commitState = error.commitState;
      rethrow;
    } catch (error, stack) {
      Error.throwWithStackTrace(
        PersistenceFailure(
          commitState: PersistenceCommitState.unknown,
          cause: error,
          stackTrace: stack,
        ),
        stack,
      );
    }
  }

  Future<Never> fail(Object error, StackTrace stack) async {
    if (_commitState == PersistenceCommitState.notCommitted) {
      try {
        await directory.deleteIfExists(recursive: true);
      } catch (cleanupError, cleanupStack) {
        throwWithCleanup(error, stack, cleanupError, cleanupStack);
      }
    }
    Error.throwWithStackTrace(error, stack);
  }

  /// Preserve registration/compensation diagnostics if a later resource release
  /// also fails. This must not change the decision about deleting output files.
  Never throwWithCleanup(
    Object error,
    StackTrace stack,
    Object cleanupError,
    StackTrace cleanupStack,
  ) {
    final persistence = error is PersistenceFailure ? error : null;
    Error.throwWithStackTrace(
      PersistenceFailure(
        commitState: _commitState,
        cause: persistence?.cause ?? error,
        stackTrace: persistence?.stackTrace ?? stack,
        cleanupFailures: [
          ...?persistence?.cleanupFailures,
          (error: cleanupError, stackTrace: cleanupStack),
        ],
      ),
      persistence?.stackTrace ?? stack,
    );
  }
}
