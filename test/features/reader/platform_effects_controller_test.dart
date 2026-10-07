import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/platform_effects_controller.dart';

class _Platform {
  final events = <String>[];
  final errors = <Object>[];
  Future<void> Function(ReaderOrientation)? onOrientation;
  Future<void> Function(bool)? onBars;
  late final coordinator = ReaderPlatformEffectsCoordinator(
    applyOrientation: (value) async {
      events.add('orientation:${value.name}');
      await onOrientation?.call(value);
    },
    applySystemBars: (visible) async {
      events.add('bars:$visible');
      await onBars?.call(visible);
    },
    onError: (error, _) => errors.add(error),
  );
  ReaderPlatformEffectsHandle reader({
    bool android = true,
    bool bars = false,
  }) => coordinator.createOwner(
    orientationEnabled: android,
    systemBarsVisible: bars,
  );
}

void main() {
  test('registration can reject an owner before native work', () async {
    final platform = _Platform();
    final reader = platform.reader();
    await reader.closeAndWait();
    await reader.attach();
    expect(reader.cycleOrientation(), isNull);
    expect(platform.events, isEmpty);
  });

  test(
    'latest owner keeps independent orientation and menu preferences',
    () async {
      final platform = _Platform();
      final old = platform.reader();
      await old.attach();
      await old.cycleOrientation();
      final current = platform.reader(bars: true);
      await current.attach();
      expect(platform.events.takeLast(2), ['orientation:system', 'bars:true']);
      expect(old.cycleOrientation(), isNull);
      await current.cycleOrientation();
      await current.cycleOrientation();
      platform.events.clear();
      await old.setSystemBarsVisible(true);
      expect(platform.events, isEmpty);
      await current.closeAndWait();
      expect(platform.events, ['orientation:portrait']);
      await old.setSystemBarsVisible(false);
      expect(platform.events.last, 'bars:false');
      await old.closeAndWait();
      expect(platform.events.takeLast(2), ['orientation:system', 'bars:true']);
    },
  );

  test('old close cannot restore over a newer reader', () async {
    final platform = _Platform();
    final old = platform.reader();
    await old.attach();
    await old.cycleOrientation();
    final current = platform.reader();
    await current.attach();
    await current.cycleOrientation();
    await current.cycleOrientation();
    platform.events.clear();
    await old.closeAndWait();
    expect(platform.events, isEmpty);
    await current.closeAndWait();
    expect(platform.events, ['orientation:system', 'bars:true']);
  });

  test(
    'close waits for both accepted requests and then restores policy',
    () async {
      final platform = _Platform();
      final orientation = Completer<void>();
      final bars = Completer<void>();
      platform.onOrientation = (_) => orientation.future;
      platform.onBars = (value) => value ? Future.value() : bars.future;
      final reader = platform.reader();
      final opening = reader.attach();
      await Future<void>.delayed(Duration.zero);
      var closed = false;
      final closing = reader.closeAndWait();
      expect(identical(closing, reader.closeAndWait()), isTrue);
      closing.then((_) => closed = true);
      expect(reader.cycleOrientation(), isNull);
      orientation.complete();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(platform.events, ['orientation:system', 'bars:false']);
      bars.complete();
      await Future.wait([opening, closing]);
      expect(closed, isTrue);
      expect(platform.events.last, 'bars:true');
    },
  );

  test('queued policy uses latest owner after pending native work', () async {
    final platform = _Platform();
    final old = platform.reader();
    await old.attach();
    final pending = Completer<void>();
    platform.onOrientation = (value) =>
        value == ReaderOrientation.portrait ? pending.future : Future.value();
    final rotating = old.cycleOrientation()!;
    await Future<void>.delayed(Duration.zero);
    final current = platform.reader(bars: true);
    final attaching = current.attach();
    final closing = old.closeAndWait();
    pending.complete();
    await Future.wait([rotating, attaching, closing]);
    expect(platform.events.takeLast(2), ['orientation:system', 'bars:true']);
    await current.closeAndWait();
  });

  for (final effect in ['orientation', 'bars']) {
    test(
      'failed $effect release retains stack and retries only that effect',
      () async {
        final platform = _Platform();
        final reader = platform.reader();
        await reader.attach();
        await reader.cycleOrientation();
        final error = StateError(effect);
        final stack = StackTrace.fromString('native $effect');
        if (effect == 'orientation') {
          platform.onOrientation = (_) => Future.error(error, stack);
        } else {
          platform.onBars = (_) => Future.error(error, stack);
        }
        platform.events.clear();
        try {
          await reader.closeAndWait();
          fail('expected release failure');
        } catch (caught, caughtStack) {
          expect(caught, same(error));
          expect(caughtStack.toString(), stack.toString());
        }
        expect(platform.events, ['orientation:system', 'bars:true']);
        expect(platform.errors, [same(error)]);
        platform.onOrientation = null;
        platform.onBars = null;
        platform.events.clear();
        await reader.closeAndWait();
        await reader.closeAndWait();
        expect(platform.events, [
          effect == 'orientation' ? 'orientation:system' : 'bars:true',
        ]);
      },
    );
  }

  test('both native failures retain causes and stable effect order', () async {
    final platform = _Platform();
    final reader = platform.reader();
    await reader.attach();
    await reader.cycleOrientation();
    final orientationError = StateError('orientation'),
        barsError = StateError('bars');
    final orientationStack = StackTrace.fromString('orientation stack'),
        barsStack = StackTrace.fromString('bars stack');
    platform.onOrientation = (_) =>
        Future.error(orientationError, orientationStack);
    platform.onBars = (_) => Future.error(barsError, barsStack);
    await expectLater(
      reader.closeAndWait(),
      throwsA(
        isA<ReaderPlatformEffectsFailure>()
            .having((f) => f.failures.map((f) => f.error).toList(), 'errors', [
              orientationError,
              barsError,
            ])
            .having(
              (f) => f.failures.map((f) => f.stackTrace).toList(),
              'stacks',
              [orientationStack, barsStack],
            ),
      ),
    );
    platform.onOrientation = null;
    platform.onBars = null;
    await reader.closeAndWait();
  });

  test('reporter failure never replaces the native error', () async {
    final error = StateError('native'), report = StateError('report');
    var failing = true;
    final coordinator = ReaderPlatformEffectsCoordinator(
      applyOrientation: (_) async {},
      applySystemBars: (_) async {
        if (failing) throw error;
      },
      onError: (_, _) => throw report,
    );
    final reader = coordinator.createOwner(orientationEnabled: false);
    await expectLater(
      reader.attach(),
      throwsA(
        isA<ReaderPlatformEffectsFailure>().having(
          (f) => f.failures.map((f) => f.error).toList(),
          'errors',
          [error, report],
        ),
      ),
    );
    failing = false;
    await reader.closeAndWait();
  });

  test('independent exit holds preserve current preferences', () async {
    final platform = _Platform();
    final reader = platform.reader();
    await reader.attach();
    await reader.cycleOrientation();
    final first = Object(), second = Object();
    await reader.hold(first, true);
    await reader.hold(second, true);
    expect(reader.cycleOrientation(), isNull);
    await reader.setSystemBarsVisible(true);
    platform.events.clear();
    await reader.hold(first, false);
    expect(platform.events, isEmpty);
    await reader.hold(second, false);
    expect(platform.events, ['orientation:portrait']);
    await reader.closeAndWait();
  });

  test('retry after a new owner reconciles the new policy', () async {
    final platform = _Platform();
    final old = platform.reader();
    await old.attach();
    await old.cycleOrientation();
    platform.onOrientation = (_) async => throw StateError('old restore');
    await expectLater(old.closeAndWait(), throwsStateError);
    platform.onOrientation = null;
    final current = platform.reader();
    await current.attach();
    await current.cycleOrientation();
    await current.cycleOrientation();
    platform.events.clear();
    await old.closeAndWait();
    expect(platform.events, isEmpty);
    await current.closeAndWait();
  });

  test('non Android owners never acquire device orientation', () async {
    final platform = _Platform();
    final reader = platform.reader(android: false);
    await reader.attach();
    expect(reader.cycleOrientation(), isNull);
    await reader.closeAndWait();
    expect(platform.events, ['bars:false', 'bars:true']);
  });

  test('idle coordinator releases the retired scheduling Zone', () async {
    final platform = _Platform();
    final pending = <void Function()>[];
    var oldClosed = false;
    runZoned(
      () {
        final old = platform.reader();
        unawaited(
          old
              .attach()
              .then((_) => old.closeAndWait())
              .then((_) => oldClosed = true),
        );
      },
      zoneSpecification: ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, task) {
          pending.add(() => zone.runGuarded(task));
        },
      ),
    );
    while (pending.isNotEmpty) {
      pending.removeAt(0)();
    }
    expect(oldClosed, isTrue);
    final current = platform.reader();
    await current.attach();
    await current.closeAndWait();
    expect(pending, isEmpty);
  });
}

extension<T> on List<T> {
  Iterable<T> takeLast(int count) => skip(length - count);
}
