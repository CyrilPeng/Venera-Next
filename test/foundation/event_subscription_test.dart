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
}
