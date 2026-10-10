import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/interactive_bindings.dart';
import 'package:venera_next/app_runtime/sync_window_binding.dart';
import 'package:venera_next/components/window_frame.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/window_placement.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';
import 'package:window_manager/window_manager.dart';

import '../support/data_sync_fixture.dart';

const _placement = WindowPlacement(Rect.fromLTWH(10, 20, 900, 700), false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'non-Windows interactive mount starts, prepares and releases placement',
    () {
      return _withTimers((timers) async {
        var reads = 0;
        final saved = <WindowPlacement>[];
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async {
            reads++;
            return _placement;
          },
          save: (value) async => saved.add(value),
        );
        final runtime = _runtime(placement: placement, windows: false);
        runtime.start();
        await pumpEventQueue();
        expect(timers, hasLength(1));
        expect(timers.single.duration, const Duration(milliseconds: 100));
        final release = await runtime.prepareForExit();
        expect(reads, 1);
        expect(saved, [_placement]);
        expect(timers.single.isActive, isFalse);
        release();
        await pumpEventQueue();
        expect(timers.last.isActive, isTrue);
        await runtime.dispose();
        expect(timers.every((timer) => !timer.isActive), isTrue);
        expect(placement.start, throwsStateError);
      });
    },
  );

  test(
    'placement saving blocks preparation while Windows heartbeat continues',
    () {
      return _withTimers((timers) async {
        final saving = Completer<void>();
        final saved = Completer<void>();
        var beats = 0;
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) {
            saving.complete();
            return saved.future;
          },
        );
        final runtime = _runtime(
          placement: placement,
          heartbeat: () async {
            beats++;
          },
        )..start();
        await pumpEventQueue();
        final preparing = runtime.prepareForExit();
        expect(identical(preparing, runtime.prepareForExit()), isTrue);
        var prepared = false;
        unawaited(preparing.then((_) => prepared = true));
        await saving.future;
        final heartbeat = timers.singleWhere(
          (timer) => timer.duration == const Duration(seconds: 1),
        );
        heartbeat.fire();
        await pumpEventQueue();
        expect(prepared, isFalse);
        expect(heartbeat.isActive, isTrue);
        expect(beats, 1);
        saved.complete();
        final release = await preparing;
        release();
        await runtime.dispose();
        expect(timers.every((timer) => !timer.isActive), isTrue);
      });
    },
  );

  test(
    'another preparation failure still drains saving and restores bindings',
    () {
      return _withTimers((timers) async {
        final saving = Completer<void>();
        final saved = Completer<void>();
        final failure = StateError('link preparation failed');
        final shares = StreamController<Object?>();
        final seen = <Object?>[];
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) {
            saving.complete();
            return saved.future;
          },
        );
        final runtime = InteractiveBindings(
          android: true,
          windows: false,
          placement: placement,
          links: () => _FailingPreparation(failure),
          shares: () => EventSubscription<Object?>(
            events: shares.stream,
            handle: (event, active) async {
              if (active()) seen.add(event);
            },
            onError: (error, stack) => fail('$error'),
          ),
          heartbeat: () async {},
        )..start();
        await pumpEventQueue();
        final preparing = runtime.prepareForExit();
        final checked = expectLater(
          preparing,
          throwsA(
            isA<InteractiveBindingsPreparationFailure>().having(
              (error) => error.failures.map((item) => item.error),
              'original preparation failure',
              contains(same(failure)),
            ),
          ),
        );
        var ended = false;
        unawaited(
          preparing.then<void>(
            (_) => ended = true,
            onError: (Object _, StackTrace _) {
              ended = true;
            },
          ),
        );
        await saving.future;
        shares.add('discarded during preparation');
        await pumpEventQueue();
        expect(ended, isFalse);
        expect(seen, isEmpty);
        expect(timers.every((timer) => !timer.isActive), isTrue);
        saved.complete();
        await checked;
        shares.add('accepted after recovery');
        await pumpEventQueue();
        expect(seen, ['accepted after recovery']);
        expect(timers.last.isActive, isTrue);
        final release = await runtime.prepareForExit();
        release();
        await runtime.dispose();
        await shares.close();
      });
    },
  );

  test(
    'placement disposal failure still joins subscriptions and heartbeat',
    () {
      return _withTimers((timers) async {
        final write = Completer<void>();
        final heartbeatDone = Completer<void>();
        final writeFailure = FileSystemException('placement write failed');
        final linkFailure = StateError('link cancellation failed');
        final errors = <Object>[];
        var shareCancelled = false;
        var heartbeatClosed = false;
        final links = StreamController<Uri>(onCancel: () => throw linkFailure);
        final shares = StreamController<Object?>(
          onCancel: () => shareCancelled = true,
        );
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) => write.future,
          onError: (error, stack) => errors.add(error),
        );
        final runtime = InteractiveBindings(
          android: true,
          windows: true,
          placement: placement,
          links: () => _bind(links.stream),
          shares: () => _bind(shares.stream),
          heartbeat: () => heartbeatDone.future,
          closeHeartbeat: () async {
            expect(heartbeatDone.isCompleted, isTrue);
            heartbeatClosed = true;
          },
        )..start();
        await pumpEventQueue();
        for (final timer in timers.toList()) {
          timer.fire();
        }
        await pumpEventQueue();
        final disposal = runtime.dispose();
        final checked = expectLater(
          disposal,
          throwsA(
            isA<InteractiveBindingsCloseFailure>().having(
              (error) => error.failures.map((item) => item.error),
              'all binding failures',
              allOf(
                contains(same(linkFailure)),
                contains(isA<WindowPlacementFailure>()),
              ),
            ),
          ),
        );
        var ended = false;
        unawaited(
          disposal.then<void>(
            (_) => ended = true,
            onError: (Object _, StackTrace _) {
              ended = true;
            },
          ),
        );
        write.completeError(writeFailure);
        await pumpEventQueue();
        expect(shareCancelled, isTrue);
        expect(errors, [writeFailure]);
        expect(ended, isFalse);
        expect(heartbeatClosed, isFalse);
        heartbeatDone.complete();
        await checked;
        expect(heartbeatClosed, isTrue);
        expect(identical(disposal, runtime.dispose()), isTrue);
        expect(timers.every((timer) => !timer.isActive), isTrue);
        await Future.wait([links.close(), shares.close()]);
      });
    },
  );

  test(
    'preparation retains both link and placement failures then allows retry',
    () {
      return _withTimers((timers) async {
        final failWrite = Completer<void>();
        final writeFailure = FileSystemException('placement unavailable');
        final linkFailure = StateError('link preparation failed');
        var failing = true;
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) async {
            if (failing) {
              await failWrite.future;
              throw writeFailure;
            }
          },
          onError: (error, stack) {},
        );
        final runtime = InteractiveBindings(
          android: true,
          windows: false,
          placement: placement,
          links: () => _FailingPreparation(linkFailure),
          shares: () => _bind(const Stream.empty()),
          heartbeat: () async {},
        )..start();
        await pumpEventQueue();
        final preparing = runtime.prepareForExit();
        final checked = expectLater(
          preparing,
          throwsA(
            isA<InteractiveBindingsPreparationFailure>().having(
              (error) => error.failures.map((item) => item.error),
              'every failing binding',
              allOf(
                contains(same(linkFailure)),
                contains(
                  isA<WindowPlacementFailure>().having(
                    (error) => error.failures.map((item) => item.error),
                    'native write cause',
                    contains(same(writeFailure)),
                  ),
                ),
              ),
            ),
          ),
        );
        failWrite.complete();
        await checked;
        failing = false;
        final release = await runtime.prepareForExit();
        release();
        await runtime.dispose();
      });
    },
  );

  test(
    'slow placement disposal does not delay stopping the native watchdog',
    () {
      return _withTimers((timers) async {
        final saving = Completer<void>();
        final finishWrite = Completer<void>();
        final heartbeatDone = Completer<void>();
        final heartbeatClosed = Completer<void>();
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) {
            saving.complete();
            return finishWrite.future;
          },
        );
        final runtime = InteractiveBindings(
          android: false,
          windows: true,
          placement: placement,
          links: () => throw StateError('unused'),
          shares: () => throw StateError('unused'),
          heartbeat: () => heartbeatDone.future,
          closeHeartbeat: () async => heartbeatClosed.complete(),
        )..start();
        await pumpEventQueue();
        for (final timer in timers.toList()) {
          timer.fire();
        }
        await saving.future;
        final disposal = runtime.dispose();
        var ended = false;
        unawaited(disposal.then((_) => ended = true));
        await pumpEventQueue();
        expect(heartbeatClosed.isCompleted, isFalse);
        heartbeatDone.complete();
        await pumpEventQueue();
        expect(heartbeatClosed.isCompleted, isTrue);
        expect(ended, isFalse);
        expect(finishWrite.isCompleted, isFalse);
        finishWrite.complete();
        await disposal;
        expect(ended, isTrue);
      });
    },
  );

  test(
    'failing resume still restores placement and other bindings exactly once',
    () {
      return _withTimers((timers) async {
        final prepareLink = Completer<void>();
        final resumeFailure = StateError('link resume failed');
        final shares = StreamController<Object?>();
        final seen = <Object?>[];
        var resumedLinks = 0;
        final placement = WindowPlacementTracker(
          ready: Future.value(),
          read: () async => _placement,
          save: (_) async {},
        );
        final runtime = InteractiveBindings(
          android: true,
          windows: false,
          placement: placement,
          links: () => _ThrowingRelease(prepareLink.future, () {
            resumedLinks++;
            throw resumeFailure;
          }),
          shares: () => EventSubscription<Object?>(
            events: shares.stream,
            handle: (event, active) async {
              if (active()) seen.add(event);
            },
            onError: (error, stack) => fail('$error'),
          ),
          heartbeat: () async {},
        )..start();
        await pumpEventQueue();
        final preparing = runtime.prepareForExit();
        await pumpEventQueue();
        // The last completed preparation is released first and must not prevent
        // the already prepared placement and share subscriptions from resuming.
        prepareLink.complete();
        final release = await preparing;
        expect(
          release,
          throwsA(
            isA<InteractiveBindingsPreparationFailure>().having(
              (error) => error.failures.map((item) => item.error),
              'resume failure',
              contains(same(resumeFailure)),
            ),
          ),
        );
        release();
        expect(resumedLinks, 1);
        shares.add('restored');
        await pumpEventQueue();
        expect(seen, ['restored']);
        expect(timers.last.isActive, isTrue);
        await runtime.dispose();
        await shares.close();
      });
    },
  );

  testWidgets(
    'window waits for placement before preparing application services',
    (tester) async {
      const channel = MethodChannel('window_manager');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final fixture = SyncTestFixture();
      addTearDown(fixture.disposeController);
      final saved = Completer<void>();
      final events = <String>[];
      final placement = WindowPlacementTracker(
        ready: Future.value(),
        read: () async => _placement,
        save: (_) {
          events.add('placement');
          return saved.future;
        },
      );
      final runtime = _runtime(placement: placement, windows: false)..start();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => WindowFrame(
            SyncWindowBinding(
              waitForHistoryWrites: () async {},
              controller: fixture.controller,
              prepareInteractive: runtime.prepareForExit,
              prepareFollowUpdates: () async {
                events.add('services');
                return () {};
              },
              child: child!,
            ),
            onExit: () => events.add('exit'),
          ),
          home: const Scaffold(),
        ),
      );
      (tester.state(find.byType(WindowFrame)) as WindowListener)
          .onWindowClose();
      await tester.pump();
      expect(events, ['placement']);
      saved.complete();
      await tester.pump();
      expect(events, ['placement', 'services', 'exit']);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.dispose);
    },
    skip: !Platform.isWindows,
  );
}

InteractiveBindings _runtime({
  required WindowPlacementTracker placement,
  bool windows = true,
  Future<void> Function()? heartbeat,
}) => InteractiveBindings(
  android: false,
  windows: windows,
  placement: placement,
  links: () => throw StateError('not used'),
  shares: () => throw StateError('not used'),
  heartbeat: heartbeat ?? () async {},
);

EventSubscription<T> _bind<T>(Stream<T> stream) => EventSubscription<T>(
  events: stream,
  handle: (event, active) async {},
  onError: (error, stack) => fail('$error'),
);

class _FailingPreparation extends EventSubscription<Uri> {
  _FailingPreparation(this.failure)
    : super(
        events: const Stream.empty(),
        handle: (event, active) async {},
        onError: (error, stack) => fail('$error'),
      );
  final Object failure;
  var _failed = false;

  @override
  Future<void Function()> prepareForExit() {
    if (!_failed) {
      _failed = true;
      return Future.error(failure);
    }
    return super.prepareForExit();
  }
}

class _ThrowingRelease extends EventSubscription<Uri> {
  _ThrowingRelease(this.ready, this.onRelease)
    : super(
        events: const Stream.empty(),
        handle: (event, active) async {},
        onError: (error, stack) => fail('$error'),
      );
  final Future<void> ready;
  final void Function() onRelease;

  @override
  Future<void Function()> prepareForExit() async {
    final release = await super.prepareForExit();
    await ready;
    return () {
      release();
      onRelease();
    };
  }
}

Future<void> _withTimers(Future<void> Function(List<_PeriodicTimer>) action) {
  final timers = <_PeriodicTimer>[];
  return runZoned(
    () => action(timers),
    zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        final timer = _PeriodicTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

class _PeriodicTimer implements Timer {
  _PeriodicTimer(this.duration, this.callback);
  final Duration duration;
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
