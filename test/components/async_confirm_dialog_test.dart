import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/foundation/persistence_failure.dart';

void main() {
  Future<void> open(WidgetTester tester, Future<void> Function() action) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAsyncConfirmDialog(
                context: context,
                title: 'Delete folder',
                content: 'Delete this folder?',
                onConfirm: action,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'confirmation waits, ignores duplicate taps and shows a retryable error',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await open(tester, () {
        calls++;
        return calls == 1 ? pending.future : Future.value();
      });
      await tester.tap(find.text('Confirm'));
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('Delete folder'), findsOneWidget);
      pending.completeError(StateError('disk unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('disk unavailable'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Delete folder'), findsNothing);
    },
  );

  testWidgets('committed failure can be acknowledged without replaying SQL', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, () async {
      calls++;
      throw PersistenceFailure(
        commitState: PersistenceCommitState.committed,
        cause: StateError('settings failed'),
        stackTrace: StackTrace.current,
      );
    });
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('late completion does not pop a newer route', (tester) async {
    final pending = Completer<void>();
    await open(tester, () => pending.future);
    await tester.tap(find.text('Confirm'));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('New route')),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 20),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('New route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('forced unmount still observes an in-flight failure', (
    tester,
  ) async {
    final pending = Completer<void>();
    await open(tester, () => pending.future);
    await tester.tap(find.text('Confirm'));
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
