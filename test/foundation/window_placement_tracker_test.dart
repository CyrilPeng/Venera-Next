import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/window_placement.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';

const _first = WindowPlacement(Rect.fromLTWH(30, 40, 1000, 700), false);
const _second = WindowPlacement(Rect.fromLTWH(50, 60, 1100, 800), true);

void main() {
  test(
    'placement preserves the persisted JSON and default validation policy',
    () {
      expect(
        WindowPlacement.defaultPlacement.rect,
        const Rect.fromLTWH(10, 10, 900, 600),
      );
      expect(WindowPlacement.defaultPlacement.isMaximized, isFalse);
      expect(_first.toJson(), {
        'width': 1000.0,
        'height': 700.0,
        'x': 30.0,
        'y': 40.0,
        'isMaximized': false,
      });
      final restored = WindowPlacement.fromJson(
        jsonDecode(jsonEncode(_first.toJson())) as Map<String, dynamic>,
      );
      expect(restored, _first);
      expect(restored.hashCode, _first.hashCode);
      expect(
        WindowPlacement.fromJson({
          'width': 1000,
          'height': 700,
          'x': 30,
          'y': 40,
          'isMaximized': false,
        }),
        _first,
      );
      expect(
        WindowPlacement.validate(const Rect.fromLTWH(-1, 0, 900, 600)),
        isFalse,
      );
      expect(
        WindowPlacement.validate(const Rect.fromLTWH(0, -1, 900, 600)),
        isFalse,
      );
      expect(
        WindowPlacement.validate(const Rect.fromLTWH(0, 0, -1, 0)),
        isTrue,
      );
      expect(() => WindowPlacement.fromJson({}), throwsA(isA<TypeError>()));
      expect(
        () => WindowPlacement.fromJson({..._first.toJson(), 'isMaximized': 1}),
        throwsA(isA<TypeError>()),
      );
    },
  );

  testWidgets('start waits for ready and its first 100ms tick', (tester) async {
    final ready = Completer<void>();
    var reads = 0;
    final saved = <WindowPlacement>[];
    final tracker = WindowPlacementTracker(
      ready: ready.future,
      read: () async {
        reads++;
        return _first;
      },
      save: (placement) async => saved.add(placement),
    );
    tracker.start();
    tracker.start();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 0);
    ready.complete();
    await tester.pump();
    expect(reads, 0);
    await tester.pump(const Duration(milliseconds: 99));
    expect(reads, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(reads, 1);
    expect(saved, [_first]);
    await tracker.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 1);
  });

  testWidgets(
    'slow native queries and saves neither overlap nor accumulate ticks',
    (tester) async {
      final read = Completer<WindowPlacement>();
      final save = Completer<void>();
      var reads = 0;
      var saves = 0;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () => ++reads == 1 ? read.future : Future.value(_first),
        save: (_) {
          saves++;
          return save.future;
        },
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 1);
      expect(saves, 0);
      read.complete(_first);
      await tester.pump();
      expect(saves, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 1);
      save.complete();
      await tester.pump();
      expect(reads, 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 2);
      expect(saves, 1);
      await tracker.dispose();
    },
  );

  testWidgets('even default placement is unknown until a write succeeds', (
    tester,
  ) async {
    var saves = 0;
    final tracker = WindowPlacementTracker(
      ready: Future.value(),
      read: () async => WindowPlacement.defaultPlacement,
      save: (_) async => saves++,
    );
    tracker.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(saves, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(saves, 1);
    await tracker.dispose();
  });

  testWidgets(
    'failed save retries unchanged placement and caches only success',
    (tester) async {
      var saves = 0;
      final errors = <Object>[];
      final failure = StateError('write failed');
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async => _first,
        save: (_) async {
          if (++saves == 1) throw failure;
        },
        onError: (error, _) => errors.add(error),
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(saves, 1);
      expect(errors, [failure]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(saves, 2);
      await tester.pump(const Duration(milliseconds: 100));
      expect(saves, 2);
      await tracker.dispose();
    },
  );

  testWidgets(
    'preparation joins accepted reads and writes before a final sample',
    (tester) async {
      final firstRead = Completer<WindowPlacement>();
      final firstSave = Completer<void>();
      final finalSave = Completer<void>();
      final events = <String>[];
      var reads = 0;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () {
          events.add('read:${++reads}');
          return reads == 1 ? firstRead.future : Future.value(_second);
        },
        save: (placement) {
          events.add(placement == _first ? 'save:first' : 'save:final');
          return placement == _first ? firstSave.future : finalSave.future;
        },
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final preparing = tracker.prepareForExit();
      var prepared = false;
      unawaited(preparing.then((_) => prepared = true));
      await tester.pump(const Duration(seconds: 2));
      expect(events, ['read:1']);
      firstRead.complete(_first);
      await tester.pump();
      expect(events, ['read:1', 'save:first']);
      expect(prepared, isFalse);
      firstSave.complete();
      await tester.pump();
      expect(events, ['read:1', 'save:first', 'read:2', 'save:final']);
      expect(prepared, isFalse);
      finalSave.complete();
      final release = await preparing;
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 2);
      release();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 3);
      await tracker.dispose();
    },
  );

  testWidgets('each prepare owns an independent idempotent hold', (
    tester,
  ) async {
    var reads = 0;
    final tracker = WindowPlacementTracker(
      ready: Future.value(),
      read: () async {
        reads++;
        return _first;
      },
      save: (_) async {},
    );
    tracker.start();
    final first = tracker.prepareForExit();
    final second = tracker.prepareForExit();
    final releases = await Future.wait([first, second]);
    expect(identical(releases[0], releases[1]), isFalse);
    expect(reads, 1);
    releases[0]();
    releases[0]();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 1);
    releases[1]();
    await tester.pump(const Duration(milliseconds: 100));
    expect(reads, 2);
    final latest = await tracker.prepareForExit();
    expect(reads, 3);
    releases[0]();
    releases[1]();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 3);
    await tracker.dispose();
    latest();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 3);
  });

  testWidgets('prepare waits for ready and saves before any periodic tick', (
    tester,
  ) async {
    final ready = Completer<void>();
    var reads = 0;
    var saves = 0;
    var prepared = false;
    final tracker = WindowPlacementTracker(
      ready: ready.future,
      read: () async {
        reads++;
        return _first;
      },
      save: (_) async => saves++,
    );
    tracker.start();
    final preparing = tracker.prepareForExit();
    unawaited(preparing.then((_) => prepared = true));
    await tester.pump(const Duration(seconds: 1));
    expect(prepared, isFalse);
    expect(reads, 0);
    ready.complete();
    final release = await preparing;
    expect(reads, 1);
    expect(saves, 1);
    release();
    await tracker.dispose();
  });

  testWidgets('dispose cancels pending readiness without late restart', (
    tester,
  ) async {
    final ready = Completer<void>();
    var reads = 0;
    final tracker = WindowPlacementTracker(
      ready: ready.future,
      read: () async {
        reads++;
        return _first;
      },
      save: (_) async {},
    );
    tracker.start();
    final preparing = expectLater(tracker.prepareForExit(), throwsStateError);
    final closing = tracker.dispose();
    expect(identical(closing, tracker.dispose()), isTrue);
    await closing;
    await preparing;
    expect(ready.isCompleted, isFalse);
    ready.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 0);
    expect(tracker.start, throwsStateError);
    await expectLater(tracker.prepareForExit(), throwsStateError);
  });

  testWidgets(
    'an unstarted owner can prepare without waiting for shared readiness',
    (tester) async {
      final ready = Completer<void>();
      var reads = 0;
      final tracker = WindowPlacementTracker(
        ready: ready.future,
        read: () async {
          reads++;
          return _first;
        },
        save: (_) async {},
      );
      final release = await tracker.prepareForExit();
      tracker.start();
      ready.complete();
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 0);
      release();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 1);
      await tracker.dispose();
    },
  );

  testWidgets(
    'dispose joins an admitted query and its save while cancelling prepare',
    (tester) async {
      final read = Completer<WindowPlacement>();
      final save = Completer<void>();
      var reads = 0;
      var saves = 0;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () {
          reads++;
          return read.future;
        },
        save: (_) {
          saves++;
          return save.future;
        },
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final preparing = expectLater(tracker.prepareForExit(), throwsStateError);
      var closed = false;
      final closing = tracker.dispose();
      unawaited(closing.then((_) => closed = true));
      await tester.pump(const Duration(seconds: 2));
      expect(closed, isFalse);
      expect(saves, 0);
      read.complete(_first);
      await tester.pump();
      expect(saves, 1);
      expect(closed, isFalse);
      save.complete();
      await closing;
      await preparing;
      expect(reads, 1);
      expect(closed, isTrue);
    },
  );

  for (final failSave in [false, true]) {
    testWidgets(
      'dispose drains the final preparation save; failure=$failSave',
      (tester) async {
        final save = Completer<void>();
        final errors = <Object>[];
        final failure = StateError('final save');
        var reads = 0;
        final tracker = WindowPlacementTracker(
          ready: Future.value(),
          read: () async {
            reads++;
            return _first;
          },
          save: (_) => save.future,
          onError: (error, _) => errors.add(error),
        );
        tracker.start();
        final preparing = expectLater(
          tracker.prepareForExit(),
          throwsStateError,
        );
        await tester.pump();
        expect(reads, 1);
        var closed = false;
        final closing = tracker.dispose();
        final result = expectLater(
          closing,
          failSave ? throwsA(isA<WindowPlacementFailure>()) : completes,
        ).then((_) => closed = true);
        await tester.pump(const Duration(seconds: 1));
        expect(closed, isFalse);
        if (failSave) {
          save.completeError(failure);
        } else {
          save.complete();
        }
        await result;
        await preparing;
        expect(errors, failSave ? [failure] : isEmpty);
        expect(identical(closing, tracker.dispose()), isTrue);
      },
    );
  }

  testWidgets(
    'a failed final query is observable once and polling can resume',
    (tester) async {
      var reads = 0;
      var failRead = true;
      final failure = StateError('getBounds failure');
      final errors = <Object>[];
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async {
          reads++;
          if (failRead) throw failure;
          return _first;
        },
        save: (_) async {},
        onError: (error, _) => errors.add(error),
      );
      tracker.start();
      await expectLater(
        tracker.prepareForExit(),
        throwsA(isA<WindowPlacementFailure>()),
      );
      expect(reads, 1);
      expect(errors, [failure]);
      failRead = false;
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 2);
      await tracker.dispose();
    },
  );

  testWidgets(
    'ready failure is observed and retained without starting queries',
    (tester) async {
      final ready = Completer<void>();
      final failure = StateError('window initialization');
      final errors = <Object>[];
      var reads = 0;
      final tracker = WindowPlacementTracker(
        ready: ready.future,
        read: () async {
          reads++;
          return _first;
        },
        save: (_) async {},
        onError: (error, _) => errors.add(error),
      );
      tracker.start();
      final preparing = expectLater(
        tracker.prepareForExit(),
        throwsA(isA<WindowPlacementFailure>()),
      );
      ready.completeError(failure);
      await preparing;
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 0);
      expect(errors, [failure]);
      await expectLater(
        tracker.dispose(),
        throwsA(isA<WindowPlacementFailure>()),
      );
    },
  );

  testWidgets(
    'minimized samples skip saves without replacing the saved state',
    (tester) async {
      final samples = <WindowPlacement?>[_second, null, null, _second];
      final saved = <WindowPlacement>[];
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async => samples.removeAt(0),
        save: (placement) async => saved.add(placement),
      );
      tracker.start();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(saved, [_second]);
      await tracker.dispose();
    },
  );

  testWidgets('a null final sample cannot acknowledge an earlier failed save', (
    tester,
  ) async {
    WindowPlacement? current = _first;
    var saves = 0;
    final failure = StateError('save failure');
    final tracker = WindowPlacementTracker(
      ready: Future.value(),
      read: () async => current,
      save: (_) async {
        if (++saves == 1) throw failure;
      },
    );
    tracker.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    current = null;
    await expectLater(
      tracker.prepareForExit(),
      throwsA(
        isA<WindowPlacementFailure>().having(
          (error) => error.cause,
          'unacknowledged save',
          same(failure),
        ),
      ),
    );
    expect(saves, 1);
    current = _first;
    final release = await tracker.prepareForExit();
    expect(saves, 2);
    release();
    await tracker.dispose();
  });

  testWidgets(
    'reporting errors preserve original failures and do not break draining',
    (tester) async {
      final readError = StateError('native query');
      final reportError = StateError('logger');
      final readStack = StackTrace.fromString('native query stack');
      final reportStack = StackTrace.fromString('report stack');
      var succeeds = false;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async {
          if (!succeeds) Error.throwWithStackTrace(readError, readStack);
          return _first;
        },
        save: (_) async {},
        onError: (_, _) => Error.throwWithStackTrace(reportError, reportStack),
      );
      tracker.start();
      await expectLater(
        tracker.prepareForExit(),
        throwsA(
          isA<WindowPlacementFailure>()
              .having(
                (failure) => failure.failures.map((entry) => entry.error),
                'both failures',
                [readError, reportError],
              )
              .having(
                (failure) => failure.failures.map(
                  (entry) => entry.stackTrace.toString(),
                ),
                'original stacks',
                [readStack.toString(), reportStack.toString()],
              ),
        ),
      );
      succeeds = true;
      await expectLater(
        tracker.prepareForExit(),
        throwsA(
          isA<WindowPlacementFailure>().having(
            (failure) => failure.failures.single.error,
            'unrepaired reporter',
            same(reportError),
          ),
        ),
      );
      await expectLater(
        tracker.dispose(),
        throwsA(isA<WindowPlacementFailure>()),
      );
    },
  );

  testWidgets(
    'an adapter can synchronously dispose and its accepted save is still joined',
    (tester) async {
      final save = Completer<void>();
      late WindowPlacementTracker tracker;
      late Future<void> closing;
      var closed = false;
      tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () {
          closing = tracker.dispose();
          unawaited(closing.then((_) => closed = true));
          return Future.value(_first);
        },
        save: (_) => save.future,
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(closed, isFalse);
      save.complete();
      await closing;
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'a failed later preparation cannot release an earlier successful hold',
    (tester) async {
      var reads = 0;
      var failRead = false;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async {
          reads++;
          if (failRead) throw StateError('later preparation');
          return _first;
        },
        save: (_) async {},
      );
      tracker.start();
      final release = await tracker.prepareForExit();
      failRead = true;
      await expectLater(
        tracker.prepareForExit(),
        throwsA(isA<WindowPlacementFailure>()),
      );
      expect(reads, 2);
      failRead = false;
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 2);
      release();
      await tester.pump(const Duration(milliseconds: 100));
      expect(reads, 3);
      await tracker.dispose();
    },
  );

  testWidgets('failed final saves never retry within the same preparation', (
    tester,
  ) async {
    var saves = 0;
    final tracker = WindowPlacementTracker(
      ready: Future.value(),
      read: () async => _first,
      save: (_) async {
        saves++;
        throw StateError('save attempt $saves');
      },
    );
    tracker.start();
    await expectLater(
      tracker.prepareForExit(),
      throwsA(isA<WindowPlacementFailure>()),
    );
    expect(saves, 1);
    await expectLater(
      tracker.prepareForExit(),
      throwsA(isA<WindowPlacementFailure>()),
    );
    expect(saves, 2);
    final closing = tracker.dispose();
    await expectLater(closing, throwsA(isA<WindowPlacementFailure>()));
    expect(identical(closing, tracker.dispose()), isTrue);
    expect(saves, 2);
  });

  testWidgets(
    'a failed partial write invalidates even the previous saved snapshot',
    (tester) async {
      var current = _first;
      var persisted = '';
      final saved = <WindowPlacement>[];
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async => current,
        save: (placement) async {
          saved.add(placement);
          if (placement == _second) {
            persisted = '{"width":';
            throw StateError('partial write');
          }
          persisted = jsonEncode(placement.toJson());
        },
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(persisted, jsonEncode(_first.toJson()));
      current = _second;
      await tester.pump(const Duration(milliseconds: 100));
      expect(persisted, '{"width":');
      current = _first;
      final release = await tracker.prepareForExit();
      expect(saved, [_first, _second, _first]);
      expect(persisted, jsonEncode(_first.toJson()));
      release();
      await tracker.dispose();
    },
  );

  testWidgets(
    'a read failure does not invalidate successfully persisted data',
    (tester) async {
      var failRead = false;
      var saves = 0;
      final tracker = WindowPlacementTracker(
        ready: Future.value(),
        read: () async {
          if (failRead) throw StateError('query failed');
          return _first;
        },
        save: (_) async => saves++,
      );
      tracker.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      failRead = true;
      await tester.pump(const Duration(milliseconds: 100));
      failRead = false;
      final release = await tracker.prepareForExit();
      expect(saves, 1);
      release();
      await tracker.dispose();
    },
  );

  for (final reporterFails in [false, true]) {
    testWidgets(
      'repeated failure diagnostics stay bounded; reporter failure=$reporterFails',
      (tester) async {
        var healthy = false;
        var attempts = 0;
        var reports = 0;
        final tracker = WindowPlacementTracker(
          ready: Future.value(),
          read: () async {
            attempts++;
            if (!healthy && attempts.isOdd) throw StateError('read $attempts');
            return _first;
          },
          save: (_) async {
            if (!healthy) throw StateError('save $attempts');
          },
          onError: (_, _) {
            reports++;
            if (reporterFails) throw StateError('report $attempts');
          },
        );
        tracker.start();
        await tester.pump();
        for (var attempt = 0; attempt < 100; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(reports, 100);
        await expectLater(
          tracker.prepareForExit(),
          throwsA(
            isA<WindowPlacementFailure>()
                .having(
                  (failure) => failure.failures.length,
                  'bounded unresolved failures',
                  reporterFails ? 4 : 2,
                )
                .having(
                  (failure) => failure.failures.first.error.toString(),
                  'latest read failure',
                  contains('read 101'),
                )
                .having(
                  (failure) => failure.failures[1].error.toString(),
                  'latest save failure',
                  contains('save 100'),
                ),
          ),
        );
        expect(reports, 101);
        healthy = true;
        if (reporterFails) {
          await expectLater(
            tracker.prepareForExit(),
            throwsA(
              isA<WindowPlacementFailure>()
                  .having(
                    (failure) => failure.failures.length,
                    'only bounded reporting failures remain',
                    2,
                  )
                  .having(
                    (failure) =>
                        failure.failures.map((entry) => entry.operation),
                    'read/save failures repaired',
                    everyElement('report'),
                  ),
            ),
          );
          await expectLater(
            tracker.dispose(),
            throwsA(isA<WindowPlacementFailure>()),
          );
        } else {
          final release = await tracker.prepareForExit();
          release();
          await tracker.dispose();
        }
      },
    );
  }
}
