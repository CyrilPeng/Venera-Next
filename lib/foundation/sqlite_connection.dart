import 'package:sqlite3/sqlite3.dart';

/// Preserves both failures when connection setup and its cleanup fail.
class SqliteConnectionSetupFailure implements Exception {
  const SqliteConnectionSetupFailure(
    this.operationError,
    this.operationStack,
    this.cleanupError,
    this.cleanupStack,
  );

  final Object operationError;
  final StackTrace operationStack;
  final Object cleanupError;
  final StackTrace cleanupStack;

  @override
  String toString() =>
      'SQLite connection setup failed: $operationError; cleanup failed: $cleanupError';
}

/// Returns an owned, configured connection. On setup failure, its owner closes
/// it once before propagating the failure. A factory transfers ownership of the
/// returned connection to this function, and must clean up if it throws first.
Database openSqliteDatabase(
  String path, {
  Database Function(String path)? databaseFactory,
}) {
  final db = (databaseFactory ?? sqlite3.open)(path);
  try {
    db.execute('PRAGMA journal_mode = DELETE;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA busy_timeout = 5000;');
    return db;
  } catch (error, stack) {
    try {
      db.dispose();
    } catch (cleanupError, cleanupStack) {
      Error.throwWithStackTrace(
        SqliteConnectionSetupFailure(error, stack, cleanupError, cleanupStack),
        stack,
      );
    }
    rethrow;
  }
}

/// Execute a function with a temporary database connection, ensuring cleanup.
/// Use this in Isolate operations to avoid manual open/dispose boilerplate.
Future<T> withDatabase<T>(
  String path,
  Future<T> Function(Database db) fn,
) async {
  final db = openSqliteDatabase(path);
  try {
    return await fn(db);
  } finally {
    db.dispose();
  }
}
