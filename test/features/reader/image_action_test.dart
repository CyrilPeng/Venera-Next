import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_action.dart';
import 'package:venera_next/foundation/image_work.dart';

void main() {
  late ImageWork work;
  late bool current;
  late Completer<Uint8List?> read;
  late Completer<void> action;
  late List<Uint8List> consumed;
  late List<Object> errors;
  late int missing;
  late int reads;
  Future<void> run() => useReaderImage(
    work: work,
    read: () {
      reads++;
      return read.future;
    },
    isCurrent: () => current,
    consume: (bytes) {
      consumed.add(bytes);
      return action.future;
    },
    onMissing: () => missing++,
    onError: errors.add,
  );
  setUp(() {
    work = ImageWork();
    current = true;
    read = Completer<Uint8List?>();
    action = Completer<void>();
    consumed = [];
    errors = [];
    missing = 0;
    reads = 0;
  });
  tearDown(() => work.dispose());

  test('inactive content never starts reading', () async {
    current = false;
    await run();
    expect(reads, 0);
  });

  for (final bytes in [
    Uint8List.fromList([7]),
    null,
  ]) {
    test(
      'queued exit suppresses a just-completed ${bytes == null ? 'missing image' : 'read'}',
      () async {
        final events = <String>[];
        late void Function() release;
        final pending = run();
        scheduleMicrotask(() {
          read.complete(bytes);
          events.add('read completed');
        });
        scheduleMicrotask(() {
          // Completion has been submitted, but its awaiting read has not resumed.
          expect(read.isCompleted, isTrue);
          release = work.holdForExit();
          events.add('held');
        });
        await pending;
        expect(events, ['read completed', 'held']);
        expect(current, isTrue);
        expect(consumed, isEmpty);
        expect(missing, 0);
        expect(errors, isEmpty);
        release();
      },
    );
  }

  test(
    'content replacement or disposal discards late bytes and misses',
    () async {
      for (final bytes in [
        Uint8List.fromList([1]),
        null,
      ]) {
        read = Completer<Uint8List?>();
        current = true;
        final pending = run();
        current = false;
        read.complete(bytes);
        await pending;
      }
      expect(consumed, isEmpty);
      expect(missing, 0);
    },
  );

  test('missing image is presented only to current owner', () async {
    final pending = run();
    read.complete(null);
    await pending;
    expect(missing, 1);
    expect(consumed, isEmpty);
  });

  test('platform action receives exact bytes and is awaited', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    var finished = false;
    final pending = run().then((_) => finished = true);
    read.complete(bytes);
    await Future<void>.delayed(Duration.zero);
    expect(consumed.single, same(bytes));
    expect(finished, isFalse);
    action.complete();
    await pending;
    expect(finished, isTrue);
  });

  test(
    'read errors are handled; obsolete errors are retained with their stack',
    () async {
      final lateFailure = StateError('obsolete read');
      final lateStack = StackTrace.fromString('obsolete read stack');
      for (final active in [true, false]) {
        current = true;
        read = Completer<Uint8List?>();
        final pending = run();
        current = active;
        read.completeError(
          active ? StateError('read') : lateFailure,
          lateStack,
        );
        await pending;
      }
      expect(errors, hasLength(1));
      expect(consumed, isEmpty);
      await expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'retained read failure',
            [(error: lateFailure, stack: lateStack)],
          ),
        ),
      );
    },
  );

  test(
    'platform failures are handled and late failures are retained',
    () async {
      final lateFailure = StateError('obsolete platform');
      final lateStack = StackTrace.fromString('obsolete platform stack');
      for (final active in [true, false]) {
        current = true;
        read = Completer<Uint8List?>();
        action = Completer<void>();
        final pending = run();
        read.complete(Uint8List(1));
        await Future<void>.delayed(Duration.zero);
        current = active;
        action.completeError(
          active ? StateError('platform') : lateFailure,
          lateStack,
        );
        await pending;
      }
      expect(errors, hasLength(1));
      expect(consumed, hasLength(2));
      await expectLater(
        work.prepareForExit(),
        throwsA(
          isA<ImageWorkFailure>().having(
            (e) => e.failures,
            'retained platform failure',
            [(error: lateFailure, stack: lateStack)],
          ),
        ),
      );
    },
  );

  for (final bytes in [
    Uint8List.fromList([1]),
    null,
  ]) {
    test(
      'exit waits for reading and suppresses late ${bytes == null ? 'missing image' : 'bytes'}',
      () async {
        var finished = false;
        var prepared = false;
        final pending = run().then((_) => finished = true);
        final preparation = work.prepareForExit().then((release) {
          prepared = true;
          return release;
        });
        await pumpEventQueue();
        expect(finished, isFalse);
        expect(prepared, isFalse);
        read.complete(bytes);
        await pending;
        final release = await preparation;
        expect(consumed, isEmpty);
        expect(missing, 0);
        expect(errors, isEmpty);

        await run();
        expect(reads, 1);
        release();
        read = Completer<Uint8List?>();
        final retry = run();
        read.complete(null);
        await retry;
        expect(reads, 2);
        expect(missing, 1);
      },
    );
  }

  test('owner disposal waits for an already started platform action', () async {
    var finished = false;
    var disposed = false;
    final pending = run().then((_) => finished = true);
    read.complete(Uint8List.fromList([2]));
    await pumpEventQueue();
    expect(consumed, hasLength(1));
    final closing = work.dispose().then((_) => disposed = true);
    await pumpEventQueue();
    expect(finished, isFalse);
    expect(disposed, isFalse);
    action.complete();
    await pending;
    await closing;
    await run();
    expect(reads, 1);
  });

  for (final duringPlatform in [false, true]) {
    test(
      'exit hold retains late ${duringPlatform ? 'platform' : 'read'} failure without presenting it',
      () async {
        final failure = StateError('held action');
        final stack = StackTrace.fromString('held action original stack');
        final pending = run();
        if (duringPlatform) {
          read.complete(Uint8List.fromList([3]));
          await pumpEventQueue();
          expect(consumed, hasLength(1));
        }
        var drained = false;
        final expected = expectLater(
          work.prepareForExit(),
          throwsA(
            isA<ImageWorkFailure>().having(
              (e) => e.failures,
              'original error and stack',
              [(error: failure, stack: stack)],
            ),
          ),
        ).then((_) => drained = true);
        await pumpEventQueue();
        expect(drained, isFalse);
        if (duringPlatform) {
          action.completeError(failure, stack);
        } else {
          read.completeError(failure, stack);
        }
        await pending;
        await expected;
        expect(errors, isEmpty);
        expect(current, isTrue);
      },
    );
  }
}
