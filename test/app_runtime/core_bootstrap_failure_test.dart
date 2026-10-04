import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/foundation/cache_manager.dart';
import 'package:venera_next/foundation/cache_scan.dart';

CoreBootstrap bootstrap({
  required List<CoreStartupCleanup> cleanup,
  required Future<void> Function() stores,
  required Future<void> Function() finish,
}) => CoreBootstrap(
  environment: () async {},
  settings: () async {},
  infrastructure: () async {},
  sources: () async {},
  stores: stores,
  finish: finish,
  failureCleanup: cleanup,
);

void main() {
  test(
    'finish failure drains cache before closing successful stores',
    () async {
      final root = Directory.systemTemp.createTempSync('core-finish-');
      addTearDown(() => root.deleteSync(recursive: true));
      final cleanup = <CoreStartupCleanup>[];
      final events = <String>[];
      final gate = Completer<CacheScanResult>();
      final enteredFinish = Completer<void>();
      final failure = StateError('finish failed');
      late Database database;
      late CacheManager cache;
      late Future<void> write;
      final core = bootstrap(
        cleanup: cleanup,
        stores: () async {
          database = sqlite3.open('${root.path}/store.db');
          cleanup.add((
            name: 'store',
            close: () {
              events.add('store');
              database.dispose();
            },
          ));
        },
        finish: () async {
          cache = CacheManager.open(
            dataPath: root.path,
            cacheRoot: root.path,
            scanner: (_, _) => gate.future,
          );
          cleanup.add((
            name: 'cache',
            close: () async {
              await cache.dispose();
              events.add('cache');
            },
          ));
          unawaited(cache.start());
          write = cache.writeCache('accepted', [1, 2]);
          enteredFinish.complete();
          throw failure;
        },
      );
      final starting = core.start();
      final checked = expectLater(starting, throwsA(same(failure)));
      await enteredFinish.future;
      await pumpEventQueue();
      expect(events, isEmpty);
      expect(database.select('SELECT 1').single.values.single, 1);
      gate.complete(const CacheScanResult(0, []));
      await checked;
      await write;
      expect(events, ['cache', 'store']);
      expect(() => database.select('SELECT 1'), throwsStateError);
      await expectLater(cache.findCache('accepted'), throwsStateError);
      expect(identical(starting, core.start()), isTrue);
      await expectLater(core.start(), throwsA(same(failure)));
      expect(events, ['cache', 'store']);
      final reopened = CacheManager.open(
        dataPath: root.path,
        cacheRoot: root.path,
      );
      try {
        expect(await (await reopened.findCache('accepted'))!.readAsBytes(), [
          1,
          2,
        ]);
      } finally {
        await reopened.dispose();
      }
    },
  );

  test('failed store group is not registered or closed twice', () async {
    final cleanup = <CoreStartupCleanup>[];
    var closes = 0;
    final failure = StateError('store');
    final core = bootstrap(
      cleanup: cleanup,
      stores: () async {
        final stores = <CoreStoreStartup>[
          (
            name: 'failing',
            initialize: () async => throw failure,
            close: () {
              closes++;
            },
          ),
        ];
        await initializeCoreStores(stores);
        cleanup.addAll(
          stores.map((store) => (name: store.name, close: store.close)),
        );
      },
      finish: () async => fail('finish must not run'),
    );
    await expectLater(core.start(), throwsA(same(failure)));
    expect(closes, 1);
    expect(cleanup, isEmpty);
  });

  test(
    'finish cleanup errors preserve cause and close earlier resources',
    () async {
      final failure = StateError('finish');
      final cleanupError = StateError('cache close');
      final events = <String>[];
      final cleanup = <CoreStartupCleanup>[];
      final core = bootstrap(
        cleanup: cleanup,
        stores: () async {
          cleanup.add((
            name: 'store',
            close: () {
              events.add('store');
            },
          ));
        },
        finish: () async {
          cleanup.add((name: 'cache', close: () => throw cleanupError));
          throw failure;
        },
      );
      await expectLater(
        core.start(),
        throwsA(
          isA<CoreStartupRollbackFailure>()
              .having((e) => e.cause, 'cause', same(failure))
              .having(
                (e) => e.cleanupFailures.single.error,
                'cleanup',
                same(cleanupError),
              ),
        ),
      );
      expect(events, ['store']);
    },
  );

  test('success retains registered resources without closing them', () async {
    final cleanup = <CoreStartupCleanup>[];
    final core = bootstrap(
      cleanup: cleanup,
      stores: () async {
        cleanup.add((name: 'store', close: () => fail('closed')));
      },
      finish: () async {},
    );
    await core.start();
    await core.start();
    expect(cleanup.length, 1);
  });
}
