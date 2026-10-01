import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/foundation/sqlite_snapshot.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('sqlite-snapshot-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'backup pins committed WAL state and preserves schema, rowids and blobs',
    () async {
      final sourcePath = '${root.path}/source.db';
      final targetPath = '${root.path}/snapshot.db';
      final writer = sqlite3.open(sourcePath);
      try {
        writer.execute('PRAGMA journal_mode = WAL;');
        writer.execute('PRAGMA wal_autocheckpoint = 0;');
        writer.execute('CREATE TABLE items (name TEXT, payload BLOB);');
        writer.execute('CREATE INDEX item_name ON items(name);');
        writer.execute(
          "INSERT INTO items(rowid, name, payload) VALUES (42, 'before', X'0001FF');",
        );
        expect(File('$sourcePath-wal').lengthSync(), greaterThan(0));
        final snapshot = createSqliteSnapshot(sourcePath, targetPath);
        writer.execute("UPDATE items SET name = 'after';");
        await snapshot;
        File(targetPath).copySync('${root.path}/standalone.db');
        final exported = sqlite3.open('${root.path}/standalone.db');
        try {
          expect(
            exported.select('PRAGMA integrity_check;').single.values.single,
            'ok',
          );
          final item = exported
              .select('SELECT rowid, name, payload FROM items;')
              .single;
          expect(item['rowid'], 42);
          expect(item['name'], 'before');
          expect(item['payload'], [0, 1, 255]);
          expect(
            exported
                .select("SELECT name FROM sqlite_master WHERE type = 'index';")
                .single['name'],
            'item_name',
          );
        } finally {
          exported.dispose();
        }
        expect(
          writer.select('SELECT name FROM items;').single['name'],
          'after',
        );
        expect(
          writer.select('PRAGMA journal_mode;').single.values.single,
          'wal',
        );
      } finally {
        writer.dispose();
      }
    },
  );

  test(
    'missing or corrupt sources do not create a source or partial target',
    () async {
      final missing = '${root.path}/missing.db';
      final target = '${root.path}/snapshot.db';
      await expectLater(
        createSqliteSnapshot(missing, target),
        throwsA(isA<SqliteException>()),
      );
      expect(File(missing).existsSync(), isFalse);
      expect(File(target).existsSync(), isFalse);
      File(missing).writeAsBytesSync(List.filled(4096, 42));
      await expectLater(
        createSqliteSnapshot(missing, target),
        throwsA(isA<SqliteException>()),
      );
      expect(File(target).existsSync(), isFalse);
      File(missing).renameSync('$missing.released');
    },
  );

  test('an existing destination is never overwritten', () async {
    final target = File('${root.path}/existing.db')..writeAsStringSync('keep');
    await expectLater(
      createSqliteSnapshot('${root.path}/source.db', target.path),
      throwsStateError,
    );
    expect(target.readAsStringSync(), 'keep');
  });
}
