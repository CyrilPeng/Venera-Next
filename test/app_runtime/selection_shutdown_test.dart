import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/source_inspection_task.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/selection_operation.dart';

import '../support/data_sync_fixture.dart';

class _Selected extends FileSelection {
  _Selected(this.release) : super('selected.cbz');
  final Future<void> Function() release;
  int releases = 0;
  @override
  Future<File> prepare() async => File(identifier);
  @override
  Future<void> dispose() async {
    releases++;
    await release();
  }
}

void main() {
  testWidgets(
    'no-window source preview keeps core alive until its original file releases',
    (tester) async {
      var storesClosed = false;
      var releaseFails = true;
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
        dataOperations: AppDataOperations(),
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              SelectionTasksScope(registry: host.selections, child: child!),
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final file = _Selected(() async {
        if (releaseFails) throw StateError('file release');
      });
      SourceSelectionOwner(context, file);
      await tester.pumpWidget(const SizedBox());
      await expectLater(host.close(), throwsA(isA<ApplicationCloseFailure>()));
      expect(storesClosed, isFalse);
      expect(file.releases, 1);
      releaseFails = false;
      await host.close();
      expect(storesClosed, isTrue);
      expect(file.releases, 2);
    },
  );

  test(
    'host preserves core through selected resource failure and retries cleanup only',
    () async {
      var storesClosed = false;
      var releaseFails = true;
      var commits = 0;
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
        dataOperations: AppDataOperations(),
      );
      final file = _Selected(() async {
        if (releaseFails) throw StateError('native release');
      });
      final operation = SelectionOperation();
      final entered = Completer<void>();
      final write = Completer<void>();
      final work = operation.run((owner) async {
        await owner.pickFile(() async => file);
        await owner.useFile(file, (_) async {
          entered.complete();
          await write.future;
          commits++;
        });
      });
      host.selections.retain(
        cancel: operation.cancel,
        close: operation.closeAndWait,
      );
      final result = expectLater(work, throwsA(isA<SelectionCleanupFailure>()));
      await entered.future;
      final closing = host.close();
      final rejected = expectLater(
        closing,
        throwsA(isA<ApplicationCloseFailure>()),
      );
      expect(host.selections.isClosing, isTrue);
      expect(storesClosed, isFalse);
      var admitted = true;
      host.selections.retain(
        cancel: () => admitted = false,
        close: () async => fail('late registration'),
      );
      expect(admitted, isFalse);
      write.complete();
      await result;
      await rejected;
      expect(storesClosed, isFalse);
      expect(commits, 1);
      releaseFails = false;
      await host.close();
      expect(storesClosed, isTrue);
      expect(commits, 1);
      expect(file.releases, 2);
    },
  );
}
