import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

void _initializeDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT);');
    db.execute("INSERT INTO items (value) VALUES ('seed');");
  } finally {
    db.dispose();
  }
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _SetupDatabase implements Database {
  _SetupDatabase(this.delegate, {this.failStatement, this.cleanupError});

  final Database delegate;
  final String? failStatement;
  final Object? cleanupError;
  final cleanupStack = StackTrace.fromString('injected cleanup stack');
  final statements = <String>[];
  Object? operationError;
  StackTrace? operationStack;
  var disposeCalls = 0;

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    statements.add(sql);
    try {
      delegate.execute(
        sql == failStatement ? 'INVALID SETUP STATEMENT;' : sql,
        parameters,
      );
    } catch (error, stack) {
      operationError = error;
      operationStack = stack;
      rethrow;
    }
  }

  @override
  void dispose() {
    disposeCalls++;
    delegate.dispose();
    if (cleanupError case final error?) {
      Error.throwWithStackTrace(error, cleanupStack);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final sqliteAvailable = _sqliteAvailable();

  group(
    'connection setup ownership',
    () {
      test('successful setup transfers the live connection to the caller', () {
        final native = sqlite3.openInMemory();
        final database = _SetupDatabase(native);
        var factoryCalls = 0;
        final connection = openSqliteDatabase(
          'requested-path',
          databaseFactory: (path) {
            factoryCalls++;
            expect(path, 'requested-path');
            return database;
          },
        );
        try {
          expect(factoryCalls, 1);
          expect(connection, same(database));
          expect(database.disposeCalls, 0);
          expect(database.statements, [
            'PRAGMA journal_mode = DELETE;',
            'PRAGMA synchronous = NORMAL;',
            'PRAGMA busy_timeout = 5000;',
          ]);
          expect(native.select('PRAGMA synchronous;').single['synchronous'], 1);
          expect(native.select('PRAGMA busy_timeout;').single['timeout'], 5000);
        } finally {
          connection.dispose();
        }
        expect(database.disposeCalls, 1);
        expect(() => native.execute('SELECT 1;'), throwsStateError);
      });

      test(
        'setup failure preserves the original SQLite error and closes once',
        () {
          final native = sqlite3.openInMemory();
          final database = _SetupDatabase(
            native,
            failStatement: 'PRAGMA synchronous = NORMAL;',
          );
          try {
            openSqliteDatabase('unused', databaseFactory: (_) => database);
            fail('Invalid setup SQL must fail');
          } catch (error, stack) {
            expect(error, isA<SqliteException>());
            expect(error, same(database.operationError));
            expect(stack.toString(), database.operationStack.toString());
          }
          expect(database.disposeCalls, 1);
          expect(database.statements, [
            'PRAGMA journal_mode = DELETE;',
            'PRAGMA synchronous = NORMAL;',
          ]);
          expect(() => native.execute('SELECT 1;'), throwsStateError);
        },
      );

      test('setup and cleanup failures retain both causes and stacks', () {
        final native = sqlite3.openInMemory();
        final cleanupError = StateError('injected dispose failure');
        final database = _SetupDatabase(
          native,
          failStatement: 'PRAGMA synchronous = NORMAL;',
          cleanupError: cleanupError,
        );
        try {
          openSqliteDatabase('unused', databaseFactory: (_) => database);
          fail('Invalid setup SQL must fail');
        } on SqliteConnectionSetupFailure catch (error, stack) {
          expect(error.operationError, isA<SqliteException>());
          expect(error.operationError, same(database.operationError));
          expect(
            error.operationStack.toString(),
            database.operationStack.toString(),
          );
          expect(error.cleanupError, same(cleanupError));
          expect(
            error.cleanupStack.toString(),
            database.cleanupStack.toString(),
          );
          expect(stack.toString(), database.operationStack.toString());
        }
        expect(database.disposeCalls, 1);
        expect(database.statements, [
          'PRAGMA journal_mode = DELETE;',
          'PRAGMA synchronous = NORMAL;',
        ]);
        expect(() => native.execute('SELECT 1;'), throwsStateError);
      });

      test('factory failures propagate before a connection is transferred', () {
        final error = StateError('open failed');
        final stack = StackTrace.fromString('injected open stack');
        var calls = 0;
        try {
          openSqliteDatabase(
            'unused',
            databaseFactory: (_) {
              calls++;
              Error.throwWithStackTrace(error, stack);
            },
          );
          fail('The factory must fail');
        } catch (failure, failureStack) {
          expect(failure, same(error));
          expect(failureStack.toString(), stack.toString());
        }
        expect(calls, 1);
      });
    },
    skip: sqliteAvailable ? false : 'sqlite3 native library is unavailable',
  );

  test('failed PRAGMA setup releases a corrupt database file', () {
    final dir = Directory.systemTemp.createTempSync('sqlite-corrupt-');
    try {
      final path = '${dir.path}/corrupt.db';
      File(path).writeAsBytesSync(List.filled(4096, 42));
      expect(() => openSqliteDatabase(path), throwsA(isA<SqliteException>()));
      File(path).renameSync('$path.failed');
      _initializeDatabase(path);
      final db = openSqliteDatabase(path);
      try {
        expect(db.select('SELECT value FROM items;').single['value'], 'seed');
      } finally {
        db.dispose();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: !sqliteAvailable);

  test(
    'openSqliteDatabase sets DELETE journal mode, NORMAL synchronous, and busy_timeout',
    () {
      final dir = Directory.systemTemp.createTempSync('venera-sqlite-helper-');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final db = openSqliteDatabase('${dir.path}/helper.db');
      addTearDown(db.dispose);

      final journalMode = db
          .select('PRAGMA journal_mode;')
          .first['journal_mode'];
      final synchronous = db.select('PRAGMA synchronous;').first['synchronous'];
      final busyTimeout = db.select('PRAGMA busy_timeout;').first['timeout'];

      expect((journalMode as String).toLowerCase(), 'delete');
      expect(synchronous, 1);
      expect(busyTimeout, 5000);
    },
    skip: sqliteAvailable ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'withDatabase opens, executes, and disposes',
    () async {
      final dir = Directory.systemTemp.createTempSync('venera-sqlite-withdb-');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final dbPath = '${dir.path}/test.db';
      _initializeDatabase(dbPath);

      final count = await withDatabase<int>(dbPath, (db) async {
        final res = db
            .select('SELECT count(*) AS count FROM items;')
            .first['count'];
        return res as int;
      });

      expect(count, 1);
    },
    skip: sqliteAvailable ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'plain sqlite3 connections hit a read-then-write lock on the same file',
    () {
      final dir = Directory.systemTemp.createTempSync('venera-sqlite-lock-');
      addTearDown(() {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final dbPath = '${dir.path}/lock.db';
      _initializeDatabase(dbPath);

      final reader = sqlite3.open(dbPath);
      final writer = sqlite3.open(dbPath);
      addTearDown(reader.dispose);
      addTearDown(writer.dispose);

      reader.execute('BEGIN;');
      reader.select('SELECT * FROM items;');

      expect(
        () => writer.execute("INSERT INTO items (value) VALUES ('locked');"),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.resultCode,
            'resultCode',
            5,
          ),
        ),
      );
    },
    skip: sqliteAvailable ? false : 'sqlite3 native library is unavailable',
  );
}
