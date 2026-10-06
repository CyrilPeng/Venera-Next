import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/application_updates.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/application_update_adapter.dart';
import '../support/data_sync_fixture.dart';

CoreBootstrap _core(Future<void> Function() close) => CoreBootstrap(
  environment: () async {},
  settings: () async {},
  infrastructure: () async {},
  sources: () async {},
  stores: () async {},
  finish: () async {},
  failureCleanup: [(name: 'stores', close: close)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = Directory.systemTemp.path;
  test(
    'host joins startup timestamp queued behind real data admission before stores close',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'application-update-startup-',
      );
      final previousPath = App.dataPath;
      final previousImplicit = Map<String, dynamic>.of(appdata.implicitData);
      App.dataPath = directory.path;
      appdata.implicitData.remove('lastCheckUpdate');
      final permit = Completer<void>();
      final held = AppDataOperations.instance.run(() => permit.future);
      final sources = SourceUpdateService();
      final startup = createStartupUpdateCheck(
        sources: sources,
        checkApplication: (_) async =>
            fail('closed startup cannot check versions'),
      );
      var closed = false;
      final core = _core(() async {
        final saved =
            jsonDecode(
                  File(
                    '${directory.path}/implicitData.json',
                  ).readAsStringSync(),
                )
                as Map;
        expect(saved['lastCheckUpdate'], isA<int>());
        closed = true;
      });
      await core.start();
      final fixture = SyncTestFixture();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: sources,
        dataOperations: AppDataOperations(),
      );
      host.attach(stop: startup.cancel, close: startup.closeAndWait);
      addTearDown(() async {
        if (!permit.isCompleted) permit.complete();
        await held;
        await host.close();
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        App.dataPath = previousPath;
        directory.deleteSync(recursive: true);
      });
      final started = startup.start();
      final closing = host.close();
      await pumpEventQueue();
      expect(closed, isFalse);
      expect(File('${directory.path}/implicitData.json').existsSync(), isFalse);
      permit.complete();
      await Future.wait([held, started, closing]);
      expect(closed, isTrue);
    },
  );

  test(
    'application HTTP cleanup failure keeps dependent core resources open',
    () async {
      final adapter = ApplicationUpdateAdapter();
      final service = ApplicationUpdateService(
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      var storesClosed = false;
      final core = _core(() async {
        storesClosed = true;
      });
      await core.start();
      final fixture = SyncTestFixture();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        applicationUpdates: service,
        dataOperations: AppDataOperations(),
      );
      final checked = expectLater(
        service.check(),
        throwsA(isA<ApplicationUpdateCleanupFailure>()),
      );
      await adapter.entered.future;
      final closing = expectLater(
        host.close(),
        throwsA(isA<ApplicationCloseFailure>()),
      );
      await adapter.draining.future;
      expect(storesClosed, isFalse);
      adapter.released.completeError(StateError('native cleanup'));
      await Future.wait([checked, closing]);
      expect(storesClosed, isFalse);
      await expectLater(host.close(), throwsA(isA<ApplicationCloseFailure>()));
      expect(storesClosed, isFalse);
      await fixture.controller.closeAndWait();
      await core.close();
    },
  );

  test(
    'host cancels independent application requests and waits native release',
    () async {
      final adapter = ApplicationUpdateAdapter();
      final service = ApplicationUpdateService(
        createClient: () => Dio()..httpClientAdapter = adapter,
        currentVersion: () => '1.0.0',
      );
      var storesClosed = false;
      final core = _core(() async {
        storesClosed = true;
      });
      await core.start();
      final fixture = SyncTestFixture();
      final host = ApplicationHost(
        core: core,
        sync: fixture.controller,
        sourceUpdates: SourceUpdateService(),
        applicationUpdates: service,
        dataOperations: AppDataOperations(),
      );
      final checked = expectLater(
        service.check(),
        throwsA(isA<RequestCancelled>()),
      );
      await adapter.entered.future;
      final closing = host.close();
      await adapter.draining.future;
      expect(storesClosed, isFalse);
      adapter.released.complete();
      await Future.wait([checked, closing]);
      expect(storesClosed, isTrue);
    },
  );
}
