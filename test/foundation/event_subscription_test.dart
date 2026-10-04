import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/event_subscription.dart';

void main() {
  test(
    'events stay ordered across awaits and duplicate start does not subscribe twice',
    () async {
      var listens = 0;
      final stream = StreamController<int>.broadcast(onListen: () => listens++);
      final gate = Completer<void>();
      final seen = <int>[];
      final binding = EventSubscription<int>(
        events: stream.stream,
        handle: (event, active) async {
          if (event == 1) await gate.future;
          if (active()) seen.add(event);
        },
        onError: (error, stack) => fail('$error'),
      );
      expect(listens, 0);
      binding.start();
      binding.start();
      stream
        ..add(1)
        ..add(2);
      await pumpEventQueue();
      expect(seen, isEmpty);
      gate.complete();
      await pumpEventQueue();
      expect(seen, [1, 2]);
      expect(listens, 1);
      await binding.dispose();
      await stream.close();
    },
  );

  test(
    'dispose invalidates an awaiting handler and drops buffered events',
    () async {
      var canceled = 0;
      final stream = StreamController<int>.broadcast(
        onCancel: () => canceled++,
      );
      final gate = Completer<void>();
      final started = <int>[];
      final delivered = <int>[];
      final binding = EventSubscription<int>(
        events: stream.stream,
        handle: (event, active) async {
          started.add(event);
          await gate.future;
          if (active()) delivered.add(event);
        },
        onError: (error, stack) => fail('$error'),
      )..start();
      stream
        ..add(1)
        ..add(2);
      await pumpEventQueue();
      final disposal = binding.dispose();
      expect(identical(disposal, binding.dispose()), isTrue);
      var disposed = false;
      unawaited(disposal.then((_) => disposed = true));
      await pumpEventQueue();
      expect(disposed, isFalse);
      expect(canceled, 1);
      gate.complete();
      await disposal;
      await pumpEventQueue();
      expect(started, [1]);
      expect(delivered, isEmpty);
      expect(canceled, 1);
      expect(binding.start, throwsStateError);
      await stream.close();
    },
  );

  test(
    'handler errors are reported without losing subsequent events',
    () async {
      final stream = StreamController<int>();
      final errors = <Object>[];
      final seen = <int>[];
      final binding = EventSubscription<int>(
        events: stream.stream,
        handle: (event, active) async {
          if (event == 1) throw StateError('handler');
          seen.add(event);
        },
        onError: (error, stack) => errors.add(error),
      )..start();
      stream
        ..add(1)
        ..add(2);
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(seen, [2]);
      await binding.dispose();
      await stream.close();
    },
  );

  test('preparation drops queued and incoming events without replay', () async {
    final stream = StreamController<int>();
    final gate = Completer<void>();
    final started = <int>[];
    final activeChecks = <bool Function()>[];
    final binding = EventSubscription<int>(
      events: stream.stream,
      handle: (event, active) async {
        started.add(event);
        activeChecks.add(active);
        if (event == 1) await gate.future;
      },
      onError: (error, stack) => fail('$error'),
    )..start();
    stream
      ..add(1)
      ..add(2);
    await pumpEventQueue();
    final preparing = binding.prepareForExit();
    expect(identical(preparing, binding.prepareForExit()), isTrue);
    var prepared = false;
    unawaited(preparing.then((_) => prepared = true));
    stream.add(3);
    await pumpEventQueue();
    expect(prepared, isFalse);
    expect(activeChecks.single(), isFalse);
    gate.complete();
    final release = await preparing;
    stream.add(4);
    await pumpEventQueue();
    release();
    release();
    stream.add(5);
    await pumpEventQueue();
    expect(started, [1, 5]);
    expect(activeChecks.first(), isFalse);
    expect(activeChecks.last(), isTrue);
    final releaseAgain = await binding.prepareForExit();
    release();
    stream.add(6);
    await pumpEventQueue();
    expect(started, [1, 5]);
    releaseAgain();
    stream.add(7);
    await pumpEventQueue();
    expect(started, [1, 5, 7]);
    await binding.dispose();
    await stream.close();
  });

  test(
    'failed cancellation joins late handler and reports its error',
    () async {
      final cancellation = StateError('cancel');
      final handlerError = StateError('handler');
      final stream = StreamController<int>(onCancel: () => throw cancellation);
      final gate = Completer<void>();
      final errors = <Object>[];
      final binding = EventSubscription<int>(
        events: stream.stream,
        handle: (event, active) async {
          await gate.future;
          throw handlerError;
        },
        onError: (error, stack) => errors.add(error),
      )..start();
      stream.add(1);
      await pumpEventQueue();
      var ended = false;
      final disposal = binding.dispose();
      final checked = expectLater(disposal, throwsA(same(cancellation)));
      unawaited(
        disposal.then(
          (_) => ended = true,
          onError: (Object _) {
            ended = true;
          },
        ),
      );
      await pumpEventQueue();
      expect(ended, isFalse);
      gate.complete();
      await checked;
      expect(errors, [handlerError]);
      await stream.close();
    },
  );

  test('dispose during preparation cannot be undone by its release', () async {
    final stream = StreamController<int>();
    final gate = Completer<void>();
    var completed = false;
    final binding = EventSubscription<int>(
      events: stream.stream,
      handle: (event, active) async {
        await gate.future;
        completed = true;
      },
      onError: (error, stack) => fail('$error'),
    )..start();
    stream.add(1);
    await pumpEventQueue();
    final preparing = binding.prepareForExit();
    final disposing = binding.dispose();
    gate.complete();
    final release = await preparing;
    await disposing;
    expect(completed, isTrue);
    release();
    expect(binding.start, throwsStateError);
    await expectLater(binding.prepareForExit(), throwsStateError);
    await stream.close();
  });

  test('a handler can initiate disposal and finish afterward', () async {
    final stream = StreamController<int>();
    final gate = Completer<void>();
    late EventSubscription<int> binding;
    late Future<void> disposal;
    var finished = false;
    binding = EventSubscription<int>(
      events: stream.stream,
      handle: (event, active) async {
        disposal = binding.dispose();
        expect(active(), isFalse);
        await gate.future;
        finished = true;
      },
      onError: (error, stack) => fail('$error'),
    )..start();
    stream.add(1);
    await pumpEventQueue();
    var disposed = false;
    unawaited(disposal.then((_) => disposed = true));
    await pumpEventQueue();
    expect(disposed, isFalse);
    gate.complete();
    await disposal;
    expect(finished, isTrue);
    await stream.close();
  });
}
