import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/interactive_bindings.dart';
import 'package:venera_next/foundation/event_subscription.dart';

EventSubscription<T> bind<T>(Stream<T> stream) => EventSubscription(
  events: stream,
  handle: (event, active) async {},
  onError: (error, stack) => fail('$error'),
);

void main() {
  test(
    'platform bindings and heartbeat attach once and stop on disposal',
    () async {
      var listens = 0;
      var cancellations = 0;
      var beats = 0;
      final links = StreamController<Uri>.broadcast(
        onListen: () => listens++,
        onCancel: () => cancellations++,
      );
      final shares = StreamController<Object?>.broadcast(
        onListen: () => listens++,
        onCancel: () => cancellations++,
      );
      final runtime = InteractiveBindings(
        android: true,
        windows: true,
        links: () => bind(links.stream),
        shares: () => bind(shares.stream),
        heartbeat: () async {
          beats++;
        },
      );
      expect(listens, 0);
      late _PeriodicTimer timer;
      runZoned(
        () {
          runtime.start();
          runtime.start();
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            expect(duration, const Duration(seconds: 1));
            return timer = _PeriodicTimer(callback);
          },
        ),
      );
      for (var i = 0; i < 3; i++) {
        timer.fire();
      }

      expect(listens, 2);
      expect(beats, 3);
      final disposal = runtime.dispose();
      expect(identical(disposal, runtime.dispose()), isTrue);

      await disposal;
      expect(timer.isActive, isFalse);
      timer
          .fire(); // Even a callback already queued before disposal is ignored.
      expect(cancellations, 2);
      expect(beats, 3);
      expect(runtime.start, throwsStateError);
      final closing = Future.wait([links.close(), shares.close()]);

      await closing;
    },
  );

  test(
    'a later attach failure cancels subscriptions already attached',
    () async {
      var cancellations = 0;
      final stream = StreamController<Uri>.broadcast(
        onCancel: () => cancellations++,
      );
      final runtime = InteractiveBindings(
        android: true,
        windows: false,
        links: () => bind(stream.stream),
        shares: () => throw StateError('platform unavailable'),
        heartbeat: () async {},
      );
      expect(runtime.start, throwsStateError);
      await runtime.dispose();
      expect(cancellations, 1);
      await stream.close();
    },
  );
}

class _PeriodicTimer implements Timer {
  _PeriodicTimer(this.callback);
  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    tick++;
    callback(this);
  }

  @override
  void cancel() => isActive = false;
}
