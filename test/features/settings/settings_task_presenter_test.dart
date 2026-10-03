import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/settings/settings_task_presenter.dart';
import 'package:venera_next/foundation/log.dart';

void main() {
  setUp(() {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'task closes progress on completion, failure=$fails, and permits retry',
      (tester) async {
        final presenter = SettingsTaskPresenter();
        final pending = Completer<String?>();
        late BuildContext owner;
        var calls = 0;
        var updates = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                owner = context;
                return const Scaffold(body: Text('Settings'));
              },
            ),
          ),
        );
        final first = presenter.run(
          owner,
          task: () {
            calls++;
            return pending.future;
          },
          errorMessage: 'Failed',
          onSuccess: () => updates++,
        );
        await tester.pump();
        await presenter.run(
          owner,
          task: () async {
            calls++;
            return null;
          },
          errorMessage: 'Failed',
        );
        expect(calls, 1);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        if (fails) {
          pending.completeError(StateError('failure'));
        } else {
          pending.complete(null);
        }
        await first;
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(updates, fails ? 0 : 1);
        await presenter.run(
          owner,
          task: () async {
            calls++;
            return null;
          },
          errorMessage: 'Failed',
          onSuccess: () => updates++,
        );
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(updates, fails ? 1 : 2);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disposed settings owner receives no late callback, failure=$fails',
      (tester) async {
        final presenter = SettingsTaskPresenter();
        final pending = Completer<String?>();
        late BuildContext owner;
        var updates = 0;
        var cleaned = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) {
                owner = context;
                return const Scaffold(body: Text('Settings'));
              },
            ),
          ),
        );
        final work = presenter.run(
          owner,
          task: () async {
            try {
              return await pending.future;
            } finally {
              cleaned = true;
            }
          },
          errorMessage: 'Failed',
          onSuccess: () => updates++,
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Replacement'))),
        );
        if (fails) {
          pending.completeError(StateError('late'));
        } else {
          pending.complete(null);
        }
        await work;
        await tester.pumpAndSettle();
        expect(cleaned, isTrue);
        expect(updates, 0);
        expect(find.text('Replacement'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reported operation failure does not publish success', (
    tester,
  ) async {
    final presenter = SettingsTaskPresenter();
    late BuildContext owner;
    var updates = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            owner = context;
            return const Scaffold();
          },
        ),
      ),
    );
    await presenter.run(
      owner,
      task: () async => 'Cannot move storage',
      errorMessage: 'Failed',
      onSuccess: () => updates++,
    );
    await tester.pumpAndSettle();
    expect(updates, 0);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
