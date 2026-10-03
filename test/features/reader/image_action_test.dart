import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_action.dart';

void main() {
  late bool current;
  late Completer<Uint8List?> read;
  late Completer<void> action;
  late List<Uint8List> consumed;
  late List<Object> errors;
  late int missing;
  late int reads;
  Future<void> run() => useReaderImage(
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
    current = true;
    read = Completer<Uint8List?>();
    action = Completer<void>();
    consumed = [];
    errors = [];
    missing = 0;
    reads = 0;
  });

  test('inactive content never starts reading', () async {
    current = false;
    await run();
    expect(reads, 0);
  });

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

  test('read errors are handled; obsolete read errors remain silent', () async {
    for (final active in [true, false]) {
      current = true;
      read = Completer<Uint8List?>();
      final pending = run();
      current = active;
      read.completeError(StateError('read'));
      await pending;
    }
    expect(errors, hasLength(1));
    expect(consumed, isEmpty);
  });

  test(
    'platform failures are handled and late failures do not present',
    () async {
      for (final active in [true, false]) {
        current = true;
        read = Completer<Uint8List?>();
        action = Completer<void>();
        final pending = run();
        read.complete(Uint8List(1));
        await Future<void>.delayed(Duration.zero);
        current = active;
        action.completeError(StateError('platform'));
        await pending;
      }
      expect(errors, hasLength(1));
      expect(consumed, hasLength(2));
    },
  );
}
