import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/features/comic_source/source_mutation_failure.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/owned_dio_client.dart';

import '../support/application_update_adapter.dart';
import '../support/data_sync_fixture.dart';

void main() {
  for (final cleanupFails in [false, true]) {
    test(
      'host waits installation cleanup before core close: fails=$cleanupFails',
      () async {
        final adapter = ApplicationUpdateAdapter();
        final queue = SourceInstallations(
          manager: _Manager(),
          repositories: SourceRepositories.instance,
          createClient: () => Dio()..httpClientAdapter = adapter,
        );
        var storesClosed = false;
        final core = CoreBootstrap(
          environment: () async {},
          settings: () async {},
          infrastructure: () async {},
          sources: () async {},
          stores: () async {},
          finish: () async {},
          failureCleanup: [
            (name: 'stores', close: () async => storesClosed = true),
          ],
        );
        await core.start();
        final fixture = SyncTestFixture();
        final host = ApplicationHost(
          core: core,
          sync: fixture.controller,
          sourceUpdates: SourceUpdateService(),
          sourceInstallations: queue,
          dataOperations: AppDataOperations(),
        );
        final task = queue.enqueueUrl('https://example.test/source.js');
        await adapter.entered.future;
        final close = host.close();
        final result = cleanupFails
            ? expectLater(close, throwsA(isA<ApplicationCloseFailure>()))
            : close;
        expect(queue.isClosed, isTrue);
        await adapter.draining.future;
        expect(storesClosed, isFalse);
        if (cleanupFails) {
          adapter.released.completeError(StateError('native cleanup'));
        } else {
          adapter.released.complete();
        }
        await result;
        expect(task.phase, SourceInstallPhase.canceled);
        expect(storesClosed, !cleanupFails);
        if (cleanupFails) {
          await expectLater(
            host.close(),
            throwsA(isA<ApplicationCloseFailure>()),
          );
          expect(storesClosed, isFalse);
          await fixture.controller.closeAndWait();
          await core.close();
        }
      },
    );
  }

  test(
    'client factory reentry registers cleanup before host can finish',
    () async {
      final adapter = ApplicationUpdateAdapter();
      late SourceInstallations queue;
      late Future<void> closing;
      queue = SourceInstallations(
        manager: _Manager(),
        repositories: SourceRepositories.instance,
        createClient: () {
          closing = queue.closeAndWait();
          return Dio()..httpClientAdapter = adapter;
        },
      );
      final task = queue.enqueueUrl('https://example.test/source.js');
      await adapter.draining.future;
      expect(adapter.entered.isCompleted, isFalse);
      var closed = false;
      final waited = closing.then((_) => closed = true);
      await pumpEventQueue();
      expect(closed, isFalse);
      adapter.released.complete();
      await waited;
      expect(task.phase, SourceInstallPhase.canceled);
    },
  );

  test(
    'download and both cleanup errors survive clearing the failed row',
    () async {
      final error = StateError('download failure');
      final closeError = StateError('close failure');
      final idleError = StateError('idle failure');
      final adapter = ApplicationUpdateAdapter()..closeError = closeError;
      final queue = SourceInstallations(
        manager: _Manager(),
        repositories: SourceRepositories.instance,
        createClient: () => Dio()..httpClientAdapter = adapter,
      );
      final task = queue.enqueueUrl('https://example.test/source.js');
      await adapter.entered.future;
      adapter.response.completeError(error);
      await adapter.draining.future;
      adapter.released.completeError(idleError);
      await pumpEventQueue();
      expect(task.phase, SourceInstallPhase.failed);
      final failure = task.cause as DioCleanupFailure;
      expect((failure.cause as DioException).error, same(error));
      expect(failure.stackTrace, isNotNull);
      expect(failure.failures.map((f) => f.error), [closeError, idleError]);
      queue.clearFinished();
      final closing = queue.closeAndWait();
      await expectLater(
        closing,
        throwsA(isA<SourceInstallationCloseFailure>()),
      );
      expect(queue.closeAndWait(), same(closing));
      expect(adapter.closes, 1);
    },
  );

  test(
    'cancellation during successful native drain cannot start installation',
    () async {
      final adapter = ApplicationUpdateAdapter();
      final queue = SourceInstallations(
        manager: _Manager(),
        repositories: SourceRepositories.instance,
        createClient: () => Dio()..httpClientAdapter = adapter,
      );
      final task = queue.enqueueUrl('https://example.test/source.js');
      await adapter.entered.future;
      adapter.response.complete(ResponseBody.fromString('// script', 200));
      await adapter.draining.future;
      final closing = queue.closeAndWait();
      adapter.released.complete();
      await closing;
      expect(task.phase, SourceInstallPhase.canceled);
    },
  );

  for (final state in SourceMutationState.values) {
    test('unresolved mutation is retained after row removal: $state', () async {
      final failure = SourceMutationFailure(
        state: state,
        failures: [
          (
            stage: 'release source',
            error: StateError('retained'),
            stack: StackTrace.current,
          ),
        ],
      );
      final queue = SourceInstallations(
        manager: _Manager(failure),
        repositories: SourceRepositories.instance,
        createClient: Dio.new,
      );
      final task = queue.enqueuePreviewedScript(
        name: 'source',
        contents: '// script',
      );
      await pumpEventQueue();
      expect(task.cause, same(failure));
      queue.clearFinished();
      await expectLater(
        queue.closeAndWait(),
        throwsA(
          isA<SourceInstallationCloseFailure>().having(
            (e) => e.failures.single.error,
            'mutation',
            same(failure),
          ),
        ),
      );
    });
  }
}

class _Manager extends Fake implements ComicSourceManager {
  _Manager([this.failure]);
  final Object? failure;
  @override
  ComicSource? find(String key) => null;

  @override
  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) async {
    beforeInstall();
    throw failure ?? TestFailure('Closed queue must not start installation');
  }
}
