import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/headless_shutdown.dart';

void main() {
  test(
    'shutdown retains bindings for late source changes and joins persistence',
    () async {
      final releaseCore = Completer<void>();
      final enteredFlush = Completer<void>();
      final releaseFlush = Completer<void>();
      final events = <String>[];
      final messages = <Map<String, dynamic>>[];
      final reported = <Object>[];
      var bindingsActive = true;
      var pendingChanges = 0;
      var persistedChanges = 0;
      var completed = false;
      var ownsDirectory = true;

      final closing = finishHeadlessRuntime(
        prepareCore: () async {
          events.add('close started');
          await releaseCore.future;
          expect(bindingsActive, isTrue);
          pendingChanges++;
          events.add('late source change');
          events.add('close finished');
        },
        disposeBindings: () {
          expect(pendingChanges, 1);
          bindingsActive = false;
          events.add('disposed');
        },
        flushPersistence: () async {
          expect(bindingsActive, isFalse);
          expect(ownsDirectory, isTrue);
          events.add('flush started');
          enteredFlush.complete();
          await releaseFlush.future;
          persistedChanges = pendingChanges;
          events.add('flush finished');
        },
        closeCore: () async {
          expect(persistedChanges, 1);
          ownsDirectory = false;
          events.add('stores closed');
        },
        emit: messages.add,
        reportError: (error, _) => reported.add(error),
      );
      unawaited(closing.then((_) => completed = true));

      await pumpEventQueue();
      expect(bindingsActive, isTrue);
      expect(events, ['close started']);
      expect(completed, isFalse);

      releaseCore.complete();
      await enteredFlush.future;
      expect(events, [
        'close started',
        'late source change',
        'close finished',
        'disposed',
        'flush started',
      ]);
      expect(persistedChanges, 0);
      expect(completed, isFalse);

      releaseFlush.complete();
      expect(await closing, isTrue);
      expect(persistedChanges, 1);
      expect(events.last, 'stores closed');
      expect(ownsDirectory, isFalse);
      expect(messages, isEmpty);
      expect(reported, isEmpty);
    },
  );

  for (final failures in [
    {'prepare'},
    {'close'},
    {'dispose'},
    {'flush'},
    {'close', 'dispose'},
    {'prepare', 'flush'},
    {'dispose', 'flush'},
    {'prepare', 'dispose', 'flush'},
  ]) {
    test(
      'shutdown joins independent cleanup after $failures failures',
      () async {
        final events = <String>[];
        final messages = <Map<String, dynamic>>[];
        final reported = <(Object, StackTrace)>[];
        final errors = {
          for (final stage in failures) stage: StateError('$stage failed'),
        };
        final stacks = {
          for (final stage in failures)
            stage: StackTrace.fromString('$stage original stack'),
        };

        void run(String stage) {
          events.add(stage);
          if (failures.contains(stage)) {
            Error.throwWithStackTrace(errors[stage]!, stacks[stage]!);
          }
        }

        final succeeded = await finishHeadlessRuntime(
          prepareCore: () async {
            await Future<void>.value();
            run('prepare');
          },
          closeCore: () async => run('close'),
          disposeBindings: () => run('dispose'),
          flushPersistence: () async {
            await Future<void>.value();
            run('flush');
          },
          emit: messages.add,
          reportError: (error, stack) => reported.add((error, stack)),
        );

        expect(succeeded, isFalse);
        expect(events, [
          'prepare',
          'dispose',
          'flush',
          if (!failures.contains('prepare') && !failures.contains('flush'))
            'close',
        ]);
        expect(messages, hasLength(failures.length));
        expect(reported, hasLength(failures.length));
        final failedStages = events.where(failures.contains).toList();
        const descriptions = {
          'prepare': 'Failed to prepare core shutdown',
          'close': 'Failed to close core resources',
          'dispose': 'Failed to release headless bindings',
          'flush': 'Failed to persist sync state',
        };
        for (var index = 0; index < failedStages.length; index++) {
          final stage = failedStages[index];
          expect(reported[index].$1, same(errors[stage]));
          expect(reported[index].$2.toString(), stacks[stage].toString());
          expect(messages[index], {
            'status': 'error',
            'message': '${descriptions[stage]}: ${errors[stage]}',
          });
        }
      },
    );
  }

  for (final callbackFailures in [
    {'report'},
    {'emit'},
    {'report', 'emit'},
  ]) {
    test(
      'diagnostic $callbackFailures failures cannot interrupt cleanup',
      () async {
        final stages = <String>[];
        final reported = <Object>[];
        final emitted = <Map<String, dynamic>>[];

        Never failStage(String stage) {
          stages.add(stage);
          throw StateError('$stage failed');
        }

        final succeeded = await finishHeadlessRuntime(
          prepareCore: () => failStage('prepare'),
          closeCore: () async =>
              fail('Unsafe storage close after failed drain'),
          disposeBindings: () => failStage('dispose'),
          flushPersistence: () => failStage('flush'),
          reportError: (error, _) {
            reported.add(error);
            if (callbackFailures.contains('report')) {
              throw StateError('logger unavailable');
            }
          },
          emit: (message) {
            emitted.add(message);
            if (callbackFailures.contains('emit')) {
              throw StateError('output unavailable');
            }
          },
        );

        expect(succeeded, isFalse);
        expect(stages, ['prepare', 'dispose', 'flush']);
        expect(reported.map((error) => error.toString()), [
          'Bad state: prepare failed',
          'Bad state: dispose failed',
          'Bad state: flush failed',
        ]);
        expect(emitted.map((message) => message['status']), [
          'error',
          'error',
          'error',
        ]);
      },
    );
  }
}
