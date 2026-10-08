import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/main.dart' as application;
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

import '../support/data_sync_fixture.dart';

CoreBootstrap _core(
  Future<void> Function() close, {
  Future<void> Function()? prepare,
}) => CoreBootstrap(
  environment: () async {},
  settings: () async {},
  infrastructure: () async {},
  sources: () async {},
  stores: () async {},
  finish: () async {},
  shutdownPreparation: prepare,
  failureCleanup: [(name: 'resource', close: close)],
);

void main() {
  test(
    'source cancellation starts before waiting for its UI and mount consumers',
    () async {
      final sources = _ClosingSourceUpdates();
      final fixture = SyncTestFixture();
      var stores = 0;
      final core = _core(() async => stores++);
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: sources,
        dataOperations: AppDataOperations(),
      );
      host.selections.retain(
        cancel: () {},
        close: () => sources.cancelled.future,
      );
      host.attach(stop: () {}, close: () => sources.cancelled.future);
      final closing = host.close();
      await pumpEventQueue();
      expect(sources.cancelled.isCompleted, isTrue);
      expect(stores, 0);
      sources.released.complete();
      await closing;
      expect(stores, 1);
    },
  );

  test(
    'each default application owns a distinct source update service',
    () async {
      final firstCore = _core(() async {}), secondCore = _core(() async {});
      await firstCore.start();
      await secondCore.start();
      final first = ApplicationHost(
        core: firstCore,
        sync: SyncTestFixture().controller,
        dataOperations: AppDataOperations(),
      );
      final second = ApplicationHost(
        core: secondCore,
        sync: SyncTestFixture().controller,
        dataOperations: AppDataOperations(),
      );
      expect(first.sourceUpdates, isNot(same(second.sourceUpdates)));
      await first.close();
      expect(first.sourceUpdates.isClosed, isTrue);
      expect(second.sourceUpdates.isClosed, isFalse);
      await second.close();
    },
  );

  testWidgets(
    'a remounted application during finalization mounts only shutdown feedback',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => false,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      final fixture = SyncTestFixture();
      final core = _core(() async {});
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      final pending = Completer<void>();
      host.attach(stop: () {}, close: () => pending.future);
      final closing = host.close();
      await tester.pumpWidget(application.MyApp(host: host));
      await tester.pump();
      expect(find.text('Closing...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pump();
      await closing;
    },
  );

  test(
    'final persistence failure keeps stores open and retries after admission seals',
    () async {
      final operations = AppDataOperations();
      var saves = 0;
      var producers = 0;
      var stores = 0;
      final fixture = SyncTestFixture(
        persistImplicit: () async {
          await operations.access(() {});
          if (++saves == 2) throw StateError('final save');
        },
      );
      final core = _core(() async {
        await operations.access(() => stores++);
      }, prepare: () async => producers++);
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: operations,
      );
      await expectLater(host.close(), throwsA(isA<ApplicationCloseFailure>()));
      expect(operations.isClosing, isTrue);
      expect(stores, 0);
      expect(producers, 1);
      await expectLater(
        operations.access(() {}),
        throwsA(isA<AppDataClosedException>()),
      );
      await host.close();
      expect(stores, 1);
      expect(producers, 1);
      expect(saves, 3);
    },
  );

  test(
    'producer failure keeps dependent stores and data admission available',
    () async {
      final operations = AppDataOperations();
      final fixture = SyncTestFixture();
      addTearDown(fixture.disposeController);
      var stores = 0;
      var producers = 0;
      final core = _core(
        () async => stores++,
        prepare: () async {
          producers++;
          throw StateError('source drain');
        },
      );
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: operations,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          host.close(),
          throwsA(isA<ApplicationCloseFailure>()),
        );
      }
      expect(stores, 0);
      expect(producers, 1);
      expect(operations.isClosing, isFalse);
      expect(await operations.access(() => 42), 42);
    },
  );
  test(
    'host retains detached mounts and sync observation through core final writes',
    () async {
      final events = <String>[];
      void Function()? changed;
      final fixture = SyncTestFixture(
        observeChanges: (listener) {
          changed = listener;
          return () {
            changed = null;
            events.add('unsubscribe');
          };
        },
        persistImplicit: () => events.add('persist'),
      );
      final core = _core(
        () async {
          events.add('stores');
        },
        prepare: () async {
          events.add('core');
          expect(changed, isNotNull);
          changed!();
        },
      );
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      fixture.controller.start();
      final oldDone = Completer<void>();
      final old = host.attach(
        stop: () => events.add('stop old'),
        close: () => oldDone.future,
      );
      final current = host.attach(
        stop: () => events.add('stop current'),
        close: () async => events.add('close current'),
      );
      expect(events, ['stop old']);
      expect(identical(old.closeAndWait(), old.closeAndWait()), isTrue);
      final closing = host.close();
      expect(identical(closing, host.close()), isTrue);
      expect(host.isClosing, isTrue);
      expect(
        () => host.attach(stop: () {}, close: () async {}),
        throwsStateError,
      );
      await pumpEventQueue();
      expect(events, isNot(contains('core')));
      oldDone.complete();
      await closing;
      await current.closeAndWait();
      expect(events.where((event) => event == 'core'), hasLength(1));
      expect(events.indexOf('core'), greaterThan(events.indexOf('persist')));
      expect(
        events.lastIndexOf('persist'),
        greaterThan(events.indexOf('core')),
      );
      expect(changed, isNull);
      expect(
        events.indexOf('stores'),
        greaterThan(events.lastIndexOf('persist')),
      );
      await host.close();
      expect(events.where((event) => event == 'core'), hasLength(1));
    },
  );

  test(
    'sync preparation failure prevents core close and can be retried',
    () async {
      var failSave = true;
      var closes = 0;
      final fixture = SyncTestFixture(
        persistImplicit: () {
          if (failSave) throw StateError('persistence');
        },
      );
      final core = _core(() async => closes++);
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      await expectLater(host.close(), throwsA(isA<ApplicationCloseFailure>()));
      expect(closes, 0);
      expect(host.isClosing, isTrue);
      failSave = false;
      await host.close();
      expect(closes, 1);
    },
  );

  test(
    'irreversible failure is retained without replaying released core resources',
    () async {
      var closes = 0;
      final fixture = SyncTestFixture();
      final error = StateError('native close');
      final core = _core(() async {
        closes++;
        throw error;
      });
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          host.close(),
          throwsA(
            isA<ApplicationCloseFailure>().having(
              (error) => error.failures.map((failure) => failure.owner),
              'owner',
              ['final persistence and stores'],
            ),
          ),
        );
      }
      expect(closes, 1);
      expect(host.isClosing, isTrue);
    },
  );

  test(
    'failed mount stop still joins release and prevents core teardown',
    () async {
      var closes = 0;
      var releases = 0;
      final fixture = SyncTestFixture();
      addTearDown(fixture.disposeController);
      final core = _core(() async => closes++);
      await core.start();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        dataOperations: AppDataOperations(),
      );
      final released = Completer<void>();
      host.attach(
        stop: () => throw StateError('stop'),
        close: () async {
          releases++;
          await released.future;
        },
      );
      var finished = false;
      final closing = host.close().whenComplete(() => finished = true);
      final checked = expectLater(
        closing,
        throwsA(isA<ApplicationCloseFailure>()),
      );
      await pumpEventQueue();
      expect(finished, isFalse);
      released.complete();
      await checked;
      await expectLater(host.close(), throwsA(isA<ApplicationCloseFailure>()));
      expect(closes, 0);
      expect(releases, 1);
      await core.close();
    },
  );
}

class _ClosingSourceUpdates extends SourceUpdateService {
  final cancelled = Completer<void>();
  final released = Completer<void>();
  @override
  Future<void> closeAndWait() {
    if (!cancelled.isCompleted) cancelled.complete();
    return released.future;
  }
}
