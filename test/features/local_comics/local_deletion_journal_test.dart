import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local_deletion_journal.dart';
import 'package:venera_next/foundation/sqlite_transaction.dart';

void main() {
  late Directory root;
  late Database db;
  late LocalDeletionJournal journal;
  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;
  Directory content(String name) {
    final directory = Directory('${root.path}/$name')..createSync();
    File('${directory.path}/page').writeAsStringSync(name);
    return directory;
  }

  void reopen() {
    db.dispose();
    db = sqlite3.open('${root.path}/journal.db');
    journal = LocalDeletionJournal(db, exists: exists)..initialize();
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('deletion-journal-');
    db = sqlite3.open('${root.path}/journal.db');
    journal = LocalDeletionJournal(db, exists: exists)..initialize();
    db.execute(
      'CREATE TABLE records(id INTEGER PRIMARY KEY); INSERT INTO records VALUES(1);',
    );
  });
  tearDown(() {
    db.dispose();
    root.deleteSync(recursive: true);
  });

  test('database failure restores staged directories and records', () async {
    final directory = content('book');
    await expectLater(
      journal.run([directory], (mark) async {
        expect(directory.existsSync(), isFalse);
        runSqliteTransaction(db, () {
          db.execute('DELETE FROM records');
          mark();
          throw StateError('database failure');
        });
      }),
      throwsStateError,
    );
    expect(File('${directory.path}/page').readAsStringSync(), 'book');
    expect(db.select('SELECT * FROM records'), hasLength(1));
    expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
  });

  test(
    'committed cleanup never removes a new directory at the original path',
    () async {
      final directory = content('book');
      await journal.run([directory, Directory('${directory.path}/nested')], (
        mark,
      ) async {
        runSqliteTransaction(db, () {
          db.execute('DELETE FROM records');
          mark();
        });
        directory.createSync();
        File('${directory.path}/new').writeAsStringSync('new owner');
      });
      expect(File('${directory.path}/new').readAsStringSync(), 'new owner');
      expect(File('${directory.path}/page').existsSync(), isFalse);
      expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
    },
  );

  test(
    'publication failure after commit never restores deleted records or files',
    () async {
      final directory = content('book');
      await expectLater(
        journal.run([directory], (mark) async {
          runSqliteTransaction(db, () {
            db.execute('DELETE FROM records');
            mark();
          });
          throw StateError('publication failure');
        }),
        throwsStateError,
      );
      expect(directory.existsSync(), isFalse);
      expect(db.select('SELECT * FROM records'), isEmpty);
      expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
    },
  );

  test(
    'cleanup interruption survives reopening and retries only quarantine',
    () async {
      final directory = content('book');
      var interrupt = true;
      final interrupted = LocalDeletionJournal(
        db,
        exists: (path) async {
          if (interrupt &&
              db
                  .select(
                    'SELECT * FROM local_deletion_journal WHERE committed = 1',
                  )
                  .isNotEmpty) {
            throw const FileSystemException('cleanup unavailable');
          }
          return exists(path);
        },
      );
      await expectLater(
        interrupted.run([directory], (mark) async {
          runSqliteTransaction(db, () {
            db.execute('DELETE FROM records');
            mark();
          });
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(db.select('SELECT * FROM local_deletion_journal'), hasLength(1));
      directory.createSync();
      File('${directory.path}/new').writeAsStringSync('keep');
      interrupt = false;
      reopen();
      await journal.recover();
      expect(File('${directory.path}/new').readAsStringSync(), 'keep');
      expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
    },
  );

  test('uncommitted movement is restored after reopening', () async {
    final directory = content('book');
    final quarantine = '${root.path}/.venera-delete-interrupted';
    db.execute(
      'INSERT INTO local_deletion_journal(original_path,quarantine_path) VALUES(?,?)',
      [directory.path, quarantine],
    );
    await directory.rename(quarantine);
    reopen();
    await journal.recover();
    expect(File('${directory.path}/page').readAsStringSync(), 'book');
    expect(db.select('SELECT * FROM records'), hasLength(1));
    expect(db.select('SELECT * FROM local_deletion_journal'), isEmpty);
  });

  test(
    'uncommitted collision preserves both directories and durable evidence',
    () async {
      final directory = content('book');
      final quarantine = content('.venera-delete-interrupted');
      db.execute(
        'INSERT INTO local_deletion_journal(original_path,quarantine_path) VALUES(?,?)',
        [directory.path, quarantine.path],
      );
      await expectLater(journal.recover(), throwsA(isA<FileSystemException>()));
      expect(File('${directory.path}/page').readAsStringSync(), 'book');
      expect(
        File('${quarantine.path}/page').readAsStringSync(),
        '.venera-delete-interrupted',
      );
      expect(db.select('SELECT * FROM local_deletion_journal'), hasLength(1));
    },
  );

  test(
    'malformed cleanup paths never delete the original or unrelated root',
    () async {
      final directory = content('book');
      db.execute(
        'INSERT INTO local_deletion_journal(original_path,quarantine_path,committed) VALUES(?,?,1)',
        [directory.path, root.path],
      );
      await expectLater(journal.recover(), throwsStateError);
      expect(File('${directory.path}/page').readAsStringSync(), 'book');
      expect(db.select('SELECT * FROM local_deletion_journal'), hasLength(1));
    },
  );
}
