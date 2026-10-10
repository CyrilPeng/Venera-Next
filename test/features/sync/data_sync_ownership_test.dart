import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/sync/data_sync_ownership.dart';
import 'package:venera_next/features/sync/data_sync_commit.dart';
import '../../support/dart_vm.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('sync-ownership-'));
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'R2 application ownership excludes other writers but permits its sync lease',
    () async {
      final application = SqliteDataSyncOwnership.applicationData(
        () => root.path,
      )..acquire();
      final other = SqliteDataSyncOwnership.applicationData(
        () => '${root.path}/.',
      );
      final sync = SqliteDataSyncOwnership(() => root.path);
      final independent = SqliteDataSyncOwnership.applicationData(
        () => '${root.path}/other',
      );
      try {
        sync.acquire();
        independent.acquire();
        expect(other.acquire, throwsA(isA<SqliteException>()));
        final directory = root.path;
        expect(
          await Isolate.run(() => _attempt(directory, application: true)),
          isFalse,
        );
        application.release();
        other.acquire();
      } finally {
        application.release();
        other.release();
        sync.release();
        independent.release();
      }
    },
  );

  test(
    'connections and isolates contend until the actual owner releases',
    () async {
      final owner = SqliteDataSyncOwnership(() => root.path)..acquire();
      final next = SqliteDataSyncOwnership(() => '${root.path}/./');
      try {
        owner.acquire();
        expect(next.acquire, throwsA(isA<SqliteException>()));
        final path = root.path;
        expect(await Isolate.run(() => _attempt(path)), isFalse);
        owner.release();
        expect(await Isolate.run(() => _attempt(path)), isTrue);
        next.acquire();
        expect(owner.acquire, throwsStateError);
      } finally {
        owner.release();
        next.release();
      }
      expect(
        File('${root.path}/${SqliteDataSyncOwnership.fileName}').existsSync(),
        isTrue,
      );
    },
  );

  test('an acquired service rejects a changed data directory', () {
    var path = root.path;
    final owner = SqliteDataSyncOwnership(() => path)..acquire();
    try {
      path = '${root.path}/different';
      expect(owner.acquire, throwsStateError);
    } finally {
      owner.release();
    }
  });

  test('failed acquisition retains a connection whose cleanup also failed', () {
    var opens = 0;
    final owner = SqliteDataSyncOwnership(
      () => root.path,
      openDatabase: (path) {
        opens++;
        return _ClosingDatabase(
          sqlite3.open(path),
          failAcquisition: opens == 1,
        );
      },
    );
    final next = SqliteDataSyncOwnership(() => root.path);
    try {
      expect(owner.acquire, throwsA(isA<DataSyncFailure>()));
      expect(next.acquire, throwsA(isA<SqliteException>()));
      owner.acquire();
      expect(opens, 2);
      expect(owner.release, throwsStateError);
      owner.release();
      next.acquire();
    } finally {
      owner.release();
      next.release();
    }
  });

  test('filesystem aliases contend for the same physical directory', () async {
    final target = Directory('${root.path}/target')..createSync();
    final alias = '${root.path}/alias';
    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'New-Item -ItemType Junction -Path \$env:SYNC_ALIAS -Target \$env:SYNC_TARGET | Out-Null',
        ],
        environment: {'SYNC_ALIAS': alias, 'SYNC_TARGET': target.path},
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
    } else {
      Link(alias).createSync(target.path);
    }
    final owner = SqliteDataSyncOwnership(() => target.path)..acquire();
    final next = SqliteDataSyncOwnership(() => alias);
    try {
      expect(next.acquire, throwsA(isA<SqliteException>()));
      owner.release();
      next.acquire();
    } finally {
      owner.release();
      next.release();
      // Remove only the alias itself before recursive test-directory cleanup.
      Link(alias).deleteSync();
    }
  });

  for (final sql in [
    'CREATE TABLE other (value TEXT)',
    'CREATE TABLE sync_owner (value TEXT); PRAGMA user_version = 1',
    'CREATE TABLE sync_owner (id INTEGER PRIMARY KEY CHECK(id = 1)); PRAGMA user_version = 2',
  ]) {
    test('unknown ownership schema is preserved: $sql', () {
      final db = sqlite3.open(
        '${root.path}/${SqliteDataSyncOwnership.fileName}',
      );
      db.execute(sql);
      final schema = db
          .select('SELECT sql FROM sqlite_master')
          .map((r) => r['sql'])
          .toList();
      db.dispose();
      final owner = SqliteDataSyncOwnership(() => root.path);
      expect(owner.acquire, throwsFormatException);
      owner.release();
      final reopened = sqlite3.open(
        '${root.path}/${SqliteDataSyncOwnership.fileName}',
      );
      try {
        expect(
          reopened.select('SELECT sql FROM sqlite_master').map((r) => r['sql']),
          schema,
        );
      } finally {
        reopened.dispose();
      }
    });
  }

  for (final suffix in ['', '-journal', '-wal', '-shm']) {
    test('non-file ownership path is rejected: $suffix', () {
      Directory(
        '${root.path}/${SqliteDataSyncOwnership.fileName}$suffix',
      ).createSync();
      final owner = SqliteDataSyncOwnership(() => root.path);
      expect(owner.acquire, throwsA(isA<FileSystemException>()));
      owner.release();
    });
  }

  test(
    'reported close failure retains the same native connection for retry',
    () {
      late _ClosingDatabase connection;
      var opens = 0;
      final owner = SqliteDataSyncOwnership(
        () => root.path,
        openDatabase: (path) {
          opens++;
          return connection = _ClosingDatabase(sqlite3.open(path));
        },
      )..acquire();
      final next = SqliteDataSyncOwnership(() => root.path);
      try {
        expect(owner.release, throwsStateError);
        expect(connection.closes, 1);
        expect(next.acquire, throwsA(isA<SqliteException>()));
        owner.release();
        expect(connection.closes, 2);
        expect(opens, 1);
        next.acquire();
      } finally {
        owner.release();
        next.release();
      }
    },
  );

  for (final application in [false, true]) {
    test(
      'independent VM excludes contenders and process death releases ownership (application=$application)',
      () async {
        final child = await Process.start(dartExecutable(), [
          '--packages=${p.absolute('.dart_tool/package_config.json')}',
          'test/fixtures/data_sync_ownership_probe.dart',
          root.path,
          if (application) 'application',
        ]);
        final output = child.stdout.transform(utf8.decoder).join();
        final errors = child.stderr.transform(utf8.decoder).join();
        var exited = false;
        final exit = child.exitCode.then((code) {
          exited = true;
          return code;
        });
        final owner = application
            ? SqliteDataSyncOwnership.applicationData(() => root.path)
            : SqliteDataSyncOwnership(() => root.path);
        try {
          final ready = File('${root.path}/owner-ready');
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!ready.existsSync() &&
              !exited &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(ready.existsSync(), isTrue);
          expect(ready.readAsStringSync(), '${child.pid}');
          expect(owner.acquire, throwsA(isA<SqliteException>()));
          expect(child.kill(ProcessSignal.sigkill), isTrue);
          expect(await exit.timeout(const Duration(seconds: 10)), isNot(0));
          owner.acquire();
          expect(await errors, isEmpty);
          expect(await output, isEmpty);
        } finally {
          owner.release();
          if (!exited) child.kill(ProcessSignal.sigkill);
          await exit.timeout(const Duration(seconds: 10));
          await child.stdin.close();
          await errors;
          await output;
        }
      },
    );
  }
}

bool _attempt(String path, {bool application = false}) {
  final owner = application
      ? SqliteDataSyncOwnership.applicationData(() => path)
      : SqliteDataSyncOwnership(() => path);
  try {
    owner.acquire();
    return true;
  } on SqliteException {
    return false;
  } finally {
    owner.release();
  }
}

// The failure is injected before native close; contention proves the real
// connection remains owned. It does not simulate a native close failing itself.
class _ClosingDatabase implements Database {
  _ClosingDatabase(this.inner, {this.failAcquisition = false});
  final Database inner;
  bool failAcquisition;
  int closes = 0;
  @override
  void dispose() {
    if (++closes == 1) throw StateError('injected close failure');
    inner.dispose();
  }

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    inner.execute(sql, parameters);
    if (failAcquisition && sql == 'BEGIN EXCLUSIVE;') {
      failAcquisition = false;
      throw StateError('injected acquisition failure');
    }
  }

  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      inner.select(sql, parameters);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
