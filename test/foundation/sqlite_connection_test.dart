import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_connection.dart';

void _initializeDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT);');
    db.execute('INSERT INTO items (value) VALUES ("seed");');
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

void main() {
  final sqliteAvailable = _sqliteAvailable();

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
        () => writer.execute('INSERT INTO items (value) VALUES ("locked");'),
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
