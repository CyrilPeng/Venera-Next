import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/application_host.dart';
import 'package:venera_next/app_runtime/core_bootstrap.dart';
import 'package:venera_next/components/image_save_binding.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/source_update_service.dart';
import 'package:venera_next/foundation/app_data_operations.dart';
import 'package:venera_next/foundation/image_save_work.dart';
import 'package:venera_next/foundation/image_work.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/request_scope.dart';

import '../support/data_sync_fixture.dart';

final _bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

Widget _app(SelectionTaskRegistry registry, ImageSaveWork work) => MaterialApp(
  home: SelectionTasksScope(
    registry: registry,
    child: ImageSaveBinding(work: work, child: const Scaffold()),
  ),
);

Future<ApplicationHost> _host(void Function() close) async {
  final core = CoreBootstrap(
    environment: () async {},
    settings: () async {},
    infrastructure: () async {},
    sources: () async {},
    stores: () async {},
    finish: () async {},
    failureCleanup: [(name: 'store', close: () async => close())],
  );
  await core.start();
  return ApplicationHost(
    core: core,
    sync: SyncTestFixture().controller,
    sourceUpdates: SourceUpdateService(),
    dataOperations: AppDataOperations(),
  );
}

void main() {
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });
  for (final delivery in [false, true]) {
    testWidgets(
      'removed no-window host drains actual image task before stores; delivery=$delivery',
      (tester) async {
        var closes = 0;
        var deliveries = 0;
        final host = await _host(() => closes++);
        final reading = Completer<Uint8List>();
        final platform = Completer<bool>();
        final work = ImageSaveWork(
          deliver: (_, _, _) {
            deliveries++;
            return platform.future;
          },
          onError: (_, _) => fail('Unexpected image error'),
        );
        await tester.pumpWidget(_app(host.selections, work));
        final saving = work.save(name: 'image', read: (_) => reading.future);
        if (delivery) reading.complete(_bytes);
        await tester.pump();
        expect(deliveries, delivery ? 1 : 0);
        await tester.pumpWidget(const SizedBox());
        final closing = host.close();
        await tester.pump();
        expect(closes, 0);
        if (delivery) {
          platform.complete(true);
        } else {
          reading.complete(_bytes);
        }
        await tester.pumpAndSettle();
        expect(await saving, delivery);
        await closing;
        expect(closes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'late image failure blocks core even after another drain consumed it',
    (tester) async {
      var closes = 0;
      final host = await _host(() => closes++);
      final reading = Completer<Uint8List>();
      final error = StateError('late native failure');
      final stack = StackTrace.fromString('original image native stack');
      final work = ImageSaveWork(
        deliver: (_, _, _) async => true,
        onError: (_, _) => fail('Detached UI must not receive error'),
      );
      await tester.pumpWidget(_app(host.selections, work));
      final saving = work.save(name: 'image', read: (_) => reading.future);
      final preparation = expectLater(
        work.prepareForExit(),
        throwsA(isA<ImageWorkFailure>()),
      );
      reading.completeError(error, stack);
      await tester.pumpAndSettle();
      await preparation;
      expect(await saving, isFalse);
      await tester.pumpWidget(const SizedBox());
      for (var attempt = 0; attempt < 2; attempt++) {
        ApplicationCloseFailure? failure;
        final closing = host.close().catchError((Object cause) {
          failure = cause as ApplicationCloseFailure;
        });
        await tester.pumpAndSettle();
        await closing;
        final selection =
            failure!.failures.single.error as SelectionCleanupFailure;
        final taskFailure =
            (selection.failures.single as ({Object error, StackTrace stack}))
                    .error
                as ImageWorkFailure;
        expect(taskFailure.failures, [(error: error, stack: stack)]);
        expect(closes, 0);
      }
      await host.sync.closeAndWait();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replaced registry retains old read while new tasks belong to new host',
    (tester) async {
      final first = SelectionTaskRegistry();
      final second = SelectionTaskRegistry();
      final oldRead = Completer<Uint8List>();
      final newRead = Completer<Uint8List>();
      final work = ImageSaveWork(
        deliver: (_, _, _) async => true,
        onError: (_, _) => fail('Unexpected image error'),
      );
      await tester.pumpWidget(_app(first, work));
      final state = tester.state(find.byType(ImageSaveBinding));
      final oldSaving = work.save(name: 'old', read: (_) => oldRead.future);
      await tester.pumpWidget(_app(second, work));
      expect(tester.state(find.byType(ImageSaveBinding)), same(state));
      late RequestScope newScope;
      final newSaving = work.save(
        name: 'new',
        read: (scope) {
          newScope = scope;
          return newRead.future;
        },
      );
      var oldClosed = false;
      final closing = first.closeAndWait().then((_) => oldClosed = true);
      await tester.pump();
      expect(oldClosed, isFalse);
      oldRead.complete(_bytes);
      await tester.pumpAndSettle();
      await closing;
      expect(await oldSaving, isFalse);
      expect(newScope.isCancelled, isFalse);
      expect(work.isBusy, isTrue);
      newRead.complete(_bytes);
      await tester.pumpAndSettle();
      expect(await newSaving, isTrue);
      await tester.pumpWidget(const SizedBox());
      await second.closeAndWait();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closed registry rejects reads from a newly mounted binding', (
    tester,
  ) async {
    final registry = SelectionTaskRegistry();
    await registry.closeAndWait();
    var reads = 0;
    final work = ImageSaveWork(
      deliver: (_, _, _) async => true,
      onError: (_, _) => fail('Unexpected image error'),
    );
    await tester.pumpWidget(_app(registry, work));
    expect(
      await work.save(
        name: 'late',
        read: (_) async {
          reads++;
          return _bytes;
        },
      ),
      isFalse,
    );
    expect(reads, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
