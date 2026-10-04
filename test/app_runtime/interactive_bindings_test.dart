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

  test(
    'disposal joins every accepted heartbeat and reports late failures',
    () async {
      final first = Completer<void>();
      final second = Completer<void>();
      final lateError = StateError('heartbeat');
      final errors = <Object>[];
      var beats = 0;
      final runtime = InteractiveBindings(
        android: false,
        windows: true,
        links: () => throw StateError('unused'),
        shares: () => throw StateError('unused'),
        heartbeat: () => ++beats == 1 ? first.future : second.future,
        onError: (error, stack) => errors.add(error),
      );
      final timer = _startWithTimer(runtime);
      timer
        ..fire()
        ..fire();
      var ended = false;
      final disposal = runtime.dispose();
      unawaited(disposal.then((_) => ended = true));
      expect(timer.isActive, isFalse);
      timer.fire();
      expect(beats, 2);
      second.completeError(lateError);
      await pumpEventQueue();
      expect(errors, [lateError]);
      expect(ended, isFalse);
      first.complete();
      await disposal;
      expect(ended, isTrue);
    },
  );

  test(
    'preparation drains platform actions and keeps the watchdog alive',
    () async {
      final links = StreamController<Uri>();
      final shares = StreamController<Object?>();
      final linkGate = Completer<void>();
      final shareGate = Completer<void>();
      final seen = <Object?>[];
      final active = <bool Function()>[];
      var beats = 0;
      EventSubscription<T> subscription<T>(
        Stream<T> stream,
        Future<void> gate,
      ) => EventSubscription<T>(
        events: stream,
        handle: (event, isActive) async {
          active.add(isActive);
          await gate;
          if (isActive()) seen.add(event);
        },
        onError: (error, stack) => fail('$error'),
      );
      final runtime = InteractiveBindings(
        android: true,
        windows: true,
        links: () => subscription(links.stream, linkGate.future),
        shares: () => subscription(shares.stream, shareGate.future),
        heartbeat: () async {
          beats++;
        },
      );
      final timer = _startWithTimer(runtime);
      links.add(Uri.parse('venera://old'));
      shares.add('old');
      await pumpEventQueue();
      final preparing = runtime.prepareForExit();
      expect(identical(preparing, runtime.prepareForExit()), isTrue);
      var prepared = false;
      unawaited(preparing.then((_) => prepared = true));
      links.add(Uri.parse('venera://rejected'));
      shares.add('rejected');
      timer.fire();
      linkGate.complete();
      await pumpEventQueue();
      expect(prepared, isFalse);
      expect(beats, 1);
      expect(timer.isActive, isTrue);
      expect(active.map((test) => test()), everyElement(isFalse));
      shareGate.complete();
      final release = await preparing;
      release();
      shares.add('new');
      await pumpEventQueue();
      expect(seen, ['new']);
      final nextRelease = await runtime.prepareForExit();
      release();
      shares.add('still rejected');
      timer.fire();
      await pumpEventQueue();
      expect(seen, ['new']);
      expect(beats, 2);
      nextRelease();
      shares.add('latest');
      await pumpEventQueue();
      expect(seen, ['new', 'latest']);
      await runtime.dispose();
      await Future.wait([links.close(), shares.close()]);
    },
  );

  for (final disposeFirst in [false, true]) {
    test(
      'start during preparation waits for release; dispose=$disposeFirst',
      () async {
        var listens = 0;
        final links = StreamController<Uri>.broadcast(
          onListen: () => listens++,
        );
        final shares = StreamController<Object?>.broadcast(
          onListen: () => listens++,
        );
        final runtime = InteractiveBindings(
          android: true,
          windows: false,
          links: () => bind(links.stream),
          shares: () => bind(shares.stream),
          heartbeat: () async {},
        );
        final release = await runtime.prepareForExit();
        runtime.start();
        expect(listens, 0);
        if (disposeFirst) await runtime.dispose();
        release();
        release();
        expect(listens, disposeFirst ? 0 : 2);
        await runtime.dispose();
        await expectLater(runtime.prepareForExit(), throwsStateError);
        await Future.wait([links.close(), shares.close()]);
      },
    );
  }

  test(
    'all cancellations are attempted and failures wait for other work',
    () async {
      final linkError = StateError('links');
      final shareError = StateError('shares');
      final stopError = StateError('stop heartbeat');
      final heartbeat = Completer<void>();
      var stops = 0;
      final links = StreamController<Uri>(onCancel: () => throw linkError);
      final shares = StreamController<Object?>(
        onCancel: () => throw shareError,
      );
      final runtime = InteractiveBindings(
        android: true,
        windows: true,
        links: () => bind(links.stream),
        shares: () => bind(shares.stream),
        heartbeat: () => heartbeat.future,
        closeHeartbeat: () async {
          expect(heartbeat.isCompleted, isTrue);
          stops++;
          throw stopError;
        },
      );
      _startWithTimer(runtime).fire();
      var ended = false;
      final disposal = runtime.dispose();
      final checked = expectLater(
        disposal,
        throwsA(
          isA<InteractiveBindingsCloseFailure>().having(
            (error) => error.failures.map((item) => item.error),
            'causes',
            unorderedEquals([linkError, shareError, stopError]),
          ),
        ),
      );
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
      expect(stops, 0);
      heartbeat.complete();
      await checked;
      await pumpEventQueue();
      expect(ended, isTrue);
      expect(stops, 1);
      expect(identical(disposal, runtime.dispose()), isTrue);
      await Future.wait([links.close(), shares.close()]);
    },
  );

  test('synchronous heartbeat failure does not stop later ticks', () async {
    final errors = <Object>[];
    final error = StateError('heartbeat');
    var beats = 0;
    final runtime = InteractiveBindings(
      android: false,
      windows: true,
      links: () => throw StateError('unused'),
      shares: () => throw StateError('unused'),
      heartbeat: () {
        if (++beats == 1) throw error;
        return Future.value();
      },
      onError: (error, stack) => errors.add(error),
    );
    final timer = _startWithTimer(runtime);
    timer
      ..fire()
      ..fire();
    await runtime.dispose();
    expect(beats, 2);
    expect(errors, [error]);
  });
}

_PeriodicTimer _startWithTimer(InteractiveBindings runtime) {
  late _PeriodicTimer timer;
  runZoned(
    runtime.start,
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        expect(duration, const Duration(seconds: 1));
        return timer = _PeriodicTimer(callback);
      },
    ),
  );
  return timer;
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
