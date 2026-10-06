import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/window_selection_task.dart';
import 'package:venera_next/features/comic_source/source_inspection_task.dart';
import 'package:venera_next/foundation/file_selection.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/foundation/selection_operation.dart';
import 'package:venera_next/network/owned_dio_client.dart';
import 'package:venera_next/network/request_scope.dart';

class _Host {
  final registry = SelectionTaskRegistry();
  late BuildContext context;
  Widget app() => MaterialApp(
    builder: (_, child) =>
        SelectionTasksScope(registry: registry, child: child!),
    home: Builder(
      builder: (value) {
        context = value;
        return const Scaffold();
      },
    ),
  );
}

class _File extends FileSelection {
  _File() : super('preview.js');
  Object? error;
  final stack = StackTrace.fromString('file release origin');
  int releases = 0;
  @override
  Future<void> dispose() async {
    releases++;
    if (error != null) Error.throwWithStackTrace(error!, stack);
  }
}

Object _retained(Object error) =>
    ((error as SelectionCleanupFailure).failures.single
            as ({Object error, StackTrace stack}))
        .error;

void main() {
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });

  testWidgets(
    'removed no-window inspection reports first cleanup failure then retries with original cause',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = SourceInspectionTask<void>(host.context);
      final file = _File()..error = StateError('release');
      final cause = StateError('read');
      final stack = StackTrace.fromString('read origin');
      final gate = Completer<void>();
      var actions = 0;
      final result = task.run(
        (_) => withSelectedFile<void>(file, (_) async {
          actions++;
          await gate.future;
          Error.throwWithStackTrace(cause, stack);
        }),
      );
      final expected = expectLater(
        result,
        throwsA(isA<FileSelectionCleanupFailure>()),
      );
      await tester.pumpWidget(const SizedBox());
      final matcher = isA<SelectionCleanupFailure>().having(
        (e) => _retained(e),
        'inspection',
        isA<FileSelectionCleanupFailure>()
            .having((e) => e.operationError, 'cause', same(cause))
            .having((e) => e.operationStack, 'stack', same(stack))
            .having((e) => e.cleanupStack, 'cleanup stack', same(file.stack)),
      );
      final closing = host.registry.closeAndWait();
      final failed = expectLater(closing, throwsA(matcher));
      await tester.pump();
      expect(file.releases, 0);
      gate.complete();
      await tester.pump();
      await expected;
      await failed;
      expect(file.releases, 1);
      final second = expectLater(
        host.registry.closeAndWait(),
        throwsA(matcher),
      );
      await tester.pump();
      await second;
      expect(file.releases, 2);
      file.error = null;
      final retry = host.registry.closeAndWait();
      await tester.pump();
      await retry;
      expect(file.releases, 3);
      expect(actions, 1);
    },
  );

  testWidgets('inspection never replays immutable HTTP cleanup failure', (
    tester,
  ) async {
    final host = _Host();
    await tester.pumpWidget(host.app());
    final task = SourceInspectionTask<void>(host.context);
    final failure = DioCleanupFailure([
      (error: StateError('HTTP close'), stack: StackTrace.current),
    ]);
    var calls = 0;
    final result = task.run((_) async {
      calls++;
      throw failure;
    });
    await expectLater(result, throwsA(same(failure)));
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await expectLater(
        host.registry.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>().having(
            _retained,
            'HTTP failure',
            same(failure),
          ),
        ),
      );
    }
    expect(calls, 1);
  });

  testWidgets(
    'host replacement retires original inspection without transferring ownership',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = SourceInspectionTask<void>(host.context);
      final gate = Completer<void>();
      final result = task.run((_) => gate.future);
      final expected = expectLater(result, throwsA(isA<RequestCancelled>()));
      final replacement = _Host();
      await tester.pumpWidget(replacement.app());
      expect(task.sameWindow, isFalse);
      expect(task.active, isFalse);
      await replacement.registry.closeAndWait();
      var closed = false;
      final original = host.registry.closeAndWait().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      gate.complete();
      await tester.pump();
      await expected;
      await original;
    },
  );

  testWidgets(
    'idle owner retains parse cause after unmount and failed retries',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final file = _File()..error = StateError('release');
      final owner = SourceSelectionOwner(host.context, file);
      final cause = FormatException('invalid preview');
      final stack = StackTrace.fromString('parse origin');
      owner.release(cause: cause, stackTrace: stack);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await expectLater(
        host.registry.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>().having(
            _retained,
            'preview',
            isA<FileSelectionCleanupFailure>()
                .having((e) => e.operationError, 'cause', same(cause))
                .having((e) => e.operationStack, 'stack', same(stack)),
          ),
        ),
      );
      file.error = null;
      await host.registry.closeAndWait();
      expect(file.releases, 3);
    },
  );

  testWidgets(
    'file release success cannot clear an underlying HTTP cleanup failure',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final task = SourceInspectionTask<void>(host.context);
      final file = _File()..error = StateError('file close');
      final stack = StackTrace.fromString('HTTP drain origin');
      final failure = DioCleanupFailure([
        (error: StateError('HTTP close'), stack: stack),
      ]);
      final result = task.run(
        (_) => withSelectedFile<void>(file, (_) async {
          Error.throwWithStackTrace(failure, stack);
        }),
      );
      await expectLater(result, throwsA(isA<FileSelectionCleanupFailure>()));
      file.error = null;
      await expectLater(
        host.registry.closeAndWait(),
        throwsA(
          isA<SelectionCleanupFailure>().having(
            _retained,
            'HTTP failure',
            same(failure),
          ),
        ),
      );
      expect(file.releases, 2);
      final closing = task.closeAndWait();
      expect(task.closeAndWait(), same(closing));
      await expectLater(closing, throwsA(same(failure)));
      expect(file.releases, 2);
    },
  );

  testWidgets('idle preview cannot transfer through a replacement host', (
    tester,
  ) async {
    final host = _Host();
    await tester.pumpWidget(host.app());
    final file = _File();
    final owner = SourceSelectionOwner(host.context, file);
    final replacement = _Host();
    await tester.pumpWidget(replacement.app());
    expect(
      () => owner.transfer((_) => fail('replacement accepted old preview')),
      throwsStateError,
    );
    await replacement.registry.closeAndWait();
    expect(file.releases, 0);
    await host.registry.closeAndWait();
    expect(file.releases, 1);
  });

  for (final outcome in ['accept', 'reject', 'throw']) {
    testWidgets('transfer reentering host close keeps ownership: $outcome', (
      tester,
    ) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      final file = _File()..error = StateError('release');
      final owner = SourceSelectionOwner(host.context, file);
      final cause = StateError('receiver rejected');
      late Future<void> closing;
      Future<void>? observed;
      void transfer() => owner.transfer((_) {
        closing = host.registry.closeAndWait();
        observed = outcome == 'accept'
            ? closing
            : expectLater(
                closing,
                throwsA(
                  isA<SelectionCleanupFailure>().having(
                    _retained,
                    'retained selection',
                    isA<FileSelectionCleanupFailure>().having(
                      (e) => e.operationError,
                      'receiver cause',
                      outcome == 'throw' ? same(cause) : isNull,
                    ),
                  ),
                ),
              );
        expectSync(file.releases, 0);
        if (outcome == 'throw') throw cause;
        return outcome == 'accept';
      });
      if (outcome == 'throw') {
        expect(transfer, throwsA(same(cause)));
      } else {
        transfer();
      }
      await tester.pump();
      await observed;
      expect(file.releases, outcome == 'accept' ? 0 : 1);
      file.error = null;
      await host.registry.closeAndWait();
      expect(file.releases, outcome == 'accept' ? 0 : 2);
      expect(() => owner.transfer((_) => true), throwsStateError);
      if (outcome == 'accept') await file.dispose();
    });
  }

  testWidgets(
    'closing host rejects adoption while original caller still owns file',
    (tester) async {
      final host = _Host();
      await tester.pumpWidget(host.app());
      await host.registry.closeAndWait();
      final file = _File();
      expect(() => SourceSelectionOwner(host.context, file), throwsStateError);
      expect(file.releases, 0);
      await file.dispose();
    },
  );
}
