import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';

void main() {
  test('late successful database is joined before reverse rollback', () async {
    final root = Directory.systemTemp.createTempSync('core-stores-');
    addTearDown(() => root.deleteSync(recursive: true));
    final ready = Completer<void>();
    final events = <String>[];
    final databases = <String, Database>{};
    final failure = StateError('favorites schema');
    CoreStoreStartup store(
      String name, {
      bool fails = false,
      bool waits = false,
    }) => (
      name: name,
      initialize: () async {
        if (waits) await ready.future;
        final db = databases[name] = sqlite3.open('${root.path}/$name.db');
        db.execute('CREATE TABLE records (id INTEGER PRIMARY KEY)');
        events.add('open $name');
        if (fails) throw failure;
      },
      close: () {
        events.add('close $name');
        databases[name]?.dispose();
      },
    );
    final result = initializeCoreStores([
      store('history'),
      store('favorites', fails: true),
      store('local', waits: true),
    ]);
    final observed = expectLater(result, throwsA(same(failure)));
    await pumpEventQueue();
    expect(events, ['open history', 'open favorites']);
    expect(
      databases['history']!
          .select('SELECT count(*) FROM records')
          .single
          .values
          .single,
      0,
    );
    ready.complete();
    await observed;
    expect(events, [
      'open history',
      'open favorites',
      'open local',
      'close local',
      'close favorites',
      'close history',
    ]);
    for (final db in databases.values) {
      expect(() => db.select('SELECT 1'), throwsStateError);
    }
  });

  test(
    'synchronous failure still joins and cleans every attempted store',
    () async {
      final events = <String>[];
      final failure = StateError('sync init');
      await expectLater(
        initializeCoreStores([
          (
            name: 'first',
            initialize: () => throw failure,
            close: () => events.add('close first'),
          ),
          (
            name: 'second',
            initialize: () async {
              events.add('open second');
            },
            close: () => events.add('close second'),
          ),
        ]),
        throwsA(same(failure)),
      );
      expect(events, ['open second', 'close second', 'close first']);
    },
  );

  test(
    'cleanup failures retain original cause and do not skip remaining closes',
    () async {
      final cause = StateError('startup');
      final cleanup = StateError('close');
      var firstClosed = false;
      await expectLater(
        initializeCoreStores([
          (
            name: 'first',
            initialize: () async {},
            close: () {
              firstClosed = true;
            },
          ),
          (
            name: 'last',
            initialize: () async => throw cause,
            close: () => throw cleanup,
          ),
        ]),
        throwsA(
          isA<CoreStartupRollbackFailure>()
              .having((e) => e.cause, 'cause', same(cause))
              .having(
                (e) => e.cleanupFailures.single.store,
                'failed owner',
                'last',
              )
              .having(
                (e) => e.cleanupFailures.single.error,
                'cleanup cause',
                same(cleanup),
              ),
        ),
      );
      expect(firstClosed, isTrue);
    },
  );

  test('successful startup retains resources for its host', () async {
    var initialized = 0;
    await initializeCoreStores([
      (
        name: 'one',
        initialize: () async {
          initialized++;
        },
        close: () => fail('Successful store closed'),
      ),
      (
        name: 'two',
        initialize: () async {
          initialized++;
        },
        close: () => fail('Successful store closed'),
      ),
    ]);
    expect(initialized, 2);
  });
}
