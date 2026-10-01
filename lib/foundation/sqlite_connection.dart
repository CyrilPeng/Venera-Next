import 'package:sqlite3/sqlite3.dart';

Database openSqliteDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA journal_mode = DELETE;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA busy_timeout = 5000;');
    return db;
  } catch (_) {
    db.dispose();
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
