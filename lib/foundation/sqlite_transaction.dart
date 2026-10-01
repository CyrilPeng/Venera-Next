import 'package:sqlite3/sqlite3.dart';

int _savepointSequence = 0;

/// Both failures remain available if SQLite cannot restore a transaction scope.
class SqliteTransactionRollbackError implements Exception {
  const SqliteTransactionRollbackError(
    this.operationError,
    this.operationStack,
    this.rollbackError,
    this.rollbackStack,
  );

  final Object operationError;
  final StackTrace operationStack;
  final Object rollbackError;
  final StackTrace rollbackStack;

  @override
  String toString() =>
      'SQLite operation failed: $operationError; rollback failed: $rollbackError';
}

/// Runs synchronous SQL work, using a savepoint inside a caller's transaction.
/// The callback must not commit/rollback the enclosing transaction, close the
/// connection, or start asynchronous work. Only the outer owner can commit it.
T runSqliteTransaction<T>(
  Database db,
  T Function() action, {
  bool immediate = false,
}) {
  final outer = db.autocommit;
  final savepoint = 'venera_scope_${_savepointSequence++}';
  db.execute(
    outer
        ? (immediate ? 'BEGIN IMMEDIATE;' : 'BEGIN TRANSACTION;')
        : 'SAVEPOINT $savepoint;',
  );
  try {
    final result = action();
    db.execute(outer ? 'COMMIT;' : 'RELEASE SAVEPOINT $savepoint;');
    return result;
  } catch (error, stack) {
    try {
      // Some SQLite errors already abort the entire transaction.
      if (!db.autocommit) {
        if (outer) {
          db.execute('ROLLBACK;');
        } else {
          db.execute('ROLLBACK TO SAVEPOINT $savepoint;');
          db.execute('RELEASE SAVEPOINT $savepoint;');
        }
      }
    } catch (rollbackError, rollbackStack) {
      throw SqliteTransactionRollbackError(
        error,
        stack,
        rollbackError,
        rollbackStack,
      );
    }
    Error.throwWithStackTrace(error, stack);
  }
}
