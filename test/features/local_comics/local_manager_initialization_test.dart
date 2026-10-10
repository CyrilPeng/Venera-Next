import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/app.dart';

void main() {
  late Directory root;
  setUp(() {
    LocalManager.current?.dispose();
    root = Directory.systemTemp.createTempSync('local-init-');
    App.dataPath = root.path;
  });
  tearDown(() {
    LocalManager.current?.dispose();
    root.deleteSync(recursive: true);
  });

  test('default dependencies stay bound until successful disposal', () async {
    final original = LocalManager(initializeSources: () async {});
    await original.init();
    expect(LocalManager(), same(original));
    expect(
      () => LocalManager(initializeSources: () async {}),
      throwsStateError,
    );
    original.dispose();
    expect(LocalManager.current, isNull);
    final replacement = LocalManager(initializeSources: () async {});
    await replacement.init();
    original.dispose();
    expect(LocalManager.current, same(replacement));
    expect(replacement.count, 0);
  });

  test(
    'failed close retains the owner and connection for disposal retry',
    () async {
      late _FailCloseDatabase connection;
      final original = LocalManager(
        initializeSources: () async {},
        openDatabase: (path) =>
            connection = _FailCloseDatabase(sqlite3.open(path)),
      );
      await original.init();
      expect(original.dispose, throwsStateError);
      expect(LocalManager.current, same(original));
      expect(connection.actual.select('SELECT 1'), hasLength(1));
      await expectLater(original.init(), throwsStateError);
      original.dispose();
      expect(LocalManager.current, isNull);
      expect(() => connection.actual.select('SELECT 1'), throwsStateError);
      expect(connection.closes, 2);
    },
  );

  test('failed initialization cannot replace an unclosed connection', () async {
    late _FailCloseDatabase connection;
    var opens = 0;
    final failure = StateError('source failed');
    final manager = LocalManager(
      initializeSources: () async => throw failure,
      openDatabase: (path) {
        opens++;
        return connection = _FailCloseDatabase(sqlite3.open(path));
      },
    );
    await expectLater(manager.init(), throwsA(same(failure)));
    await expectLater(manager.init(), throwsStateError);
    expect(opens, 1);
    expect(connection.actual.select('SELECT 1'), hasLength(1));
    manager.dispose();
    expect(LocalManager.current, isNull);
    expect(() => connection.actual.select('SELECT 1'), throwsStateError);
  });

  test(
    'concurrent and completed initialization reuse one connection and future',
    () async {
      var opens = 0;
      var sourceInitializations = 0;
      final started = Completer<void>();
      final release = Completer<void>();
      late Database connection;
      final manager = LocalManager.independent(
        openDatabase: (path) {
          opens++;
          return connection = sqlite3.open(path);
        },
        initializeSources: () {
          sourceInitializations++;
          started.complete();
          return release.future;
        },
      );
      addTearDown(manager.dispose);
      final first = manager.init();
      final second = manager.init();
      expect(identical(first, second), isTrue);
      await started.future;
      expect(opens, 1);
      release.complete();
      await first;
      connection.execute('CREATE TEMP TABLE owned_connection (id INTEGER);');
      expect(identical(first, manager.init()), isTrue);
      await manager.init();
      expect(connection.select('SELECT * FROM owned_connection'), isEmpty);
      expect(opens, 1);
      expect(sourceInitializations, 1);
    },
  );

  test('failed initialization closes the connection and can retry', () async {
    final connections = <Database>[];
    var fail = true;
    final expected = StateError('source initialization failed');
    final manager = LocalManager.independent(
      openDatabase: (path) {
        final database = sqlite3.open(path);
        connections.add(database);
        return database;
      },
      initializeSources: () async {
        if (fail) throw expected;
      },
    );
    addTearDown(manager.dispose);
    await expectLater(manager.init(), throwsA(same(expected)));
    expect(() => connections.single.select('SELECT 1'), throwsStateError);
    expect(() => manager.count, throwsStateError);
    fail = false;
    await manager.init();
    expect(connections, hasLength(2));
    expect(manager.count, 0);
    manager.dispose();
    expect(() => connections.last.select('SELECT 1'), throwsStateError);
  });

  test(
    'dispose during initialization blocks late publication and reopening',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      late Database connection;
      final manager = LocalManager.independent(
        openDatabase: (path) => connection = sqlite3.open(path),
        initializeSources: () {
          started.complete();
          return release.future;
        },
      );
      final initializing = manager.init();
      await started.future;
      manager.dispose();
      expect(() => connection.select('SELECT 1'), throwsStateError);
      final failed = expectLater(initializing, throwsStateError);
      release.complete();
      await failed;
      await expectLater(manager.init(), throwsStateError);
      manager.dispose();
      expect(manager.downloadingTasks, isEmpty);
    },
  );

  test(
    'dispose before initialization is safe and forbids opening resources',
    () async {
      var opens = 0;
      final manager = LocalManager.independent(
        openDatabase: (path) {
          opens++;
          return sqlite3.open(path);
        },
        initializeSources: () async {},
      );
      manager.dispose();
      manager.dispose();
      await expectLater(manager.init(), throwsStateError);
      expect(opens, 0);
    },
  );
}

class _FailCloseDatabase extends Fake implements Database {
  _FailCloseDatabase(this.actual);
  final Database actual;
  int closes = 0;
  @override
  bool get autocommit => actual.autocommit;
  @override
  void execute(String sql, [List<Object?> parameters = const []]) =>
      actual.execute(sql, parameters);
  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      actual.select(sql, parameters);
  @override
  void dispose() {
    if (++closes == 1) throw StateError('close failed');
    actual.dispose();
  }
}
