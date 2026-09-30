import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/app_runtime/background_sync.dart';

void main() {
  test('restart cancels old timer ownership and ignores stale ticks', () {
    var starts = 0;
    var stops = 0;
    var checks = 0;
    final timers = <_Timer>[];
    final runtime = BackgroundSync(
      startDataSync: () => starts++,
      stopDataSync: () => stops++,
      checkLibrary: () => checks++,
    );
    void start() => runZoned(
      runtime.start,
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          expect(duration, const Duration(minutes: 15));
          final timer = _Timer(callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    expect(checks, 0);
    start();
    start();
    expect(starts, 1);
    expect(timers, hasLength(1));
    timers.first.fire();
    expect(checks, 2);
    runtime.stop();
    runtime.stop();
    expect(stops, 1);
    expect(timers.first.isActive, isFalse);
    start();
    expect(starts, 2);
    expect(checks, 3);
    timers.first.fire();
    expect(checks, 3);
    timers.last.fire();
    expect(checks, 4);
    runtime.stop();
    expect(timers.last.isActive, isFalse);
  });

  test('failed startup detaches data synchronization', () {
    var stops = 0;
    final runtime = BackgroundSync(
      startDataSync: () {},
      stopDataSync: () => stops++,
      checkLibrary: () => throw StateError('unavailable'),
    );
    expect(runtime.start, throwsStateError);
    runtime.stop();
    expect(stops, 1);
  });
}

class _Timer implements Timer {
  _Timer(this.callback);
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
