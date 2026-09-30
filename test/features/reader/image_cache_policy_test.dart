import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/reader/image_cache_policy.dart';

void main() {
  test('memory thresholds retain the existing cache limits', () {
    for (final entry in <int, int>{
      0: 100,
      (1 << 30) - 1: 100,
      1 << 30: 200,
      (2 << 30) - 1: 200,
      2 << 30: 300,
      (4 << 30) - 1: 300,
      4 << 30: 500,
      8 << 30: 500,
    }.entries) {
      expect(
        ReaderImageCachePolicy.limitForMemory(entry.key),
        entry.value << 20,
      );
    }
  });

  test('exit resets the cache once and ignores a late memory query', () async {
    final query = Completer<int?>();
    final limits = <int>[];
    var calls = 0;
    final policy = ReaderImageCachePolicy(
      readAvailableMemory: () {
        calls++;
        return query.future;
      },
      setLimit: limits.add,
      onConfigured: (_, _) => fail('late configuration'),
      onError: (error, stack) => fail('$error'),
    );
    final pending = policy.configure();
    policy.dispose();
    policy.dispose();
    await policy.configure();
    query.complete(8 << 30);
    await pending;
    expect(limits, [100 << 20]);
    expect(calls, 1);
  });

  test('only the latest query may configure or report errors', () async {
    final queries = [Completer<int?>(), Completer<int?>(), Completer<int?>()];
    var calls = 0;
    final limits = <int>[];
    final configured = <int>[];
    final policy = ReaderImageCachePolicy(
      readAvailableMemory: () => queries[calls++].future,
      setLimit: limits.add,
      onConfigured: (memory, limit) => configured.add(memory),
      onError: (error, stack) => fail('$error'),
    );
    final old = policy.configure();
    final obsolete = policy.configure();
    final current = policy.configure();
    queries[2].complete(2 << 30);
    await current;
    queries[0].complete(8 << 30);
    queries[1].completeError(StateError('obsolete'));
    await Future.wait([old, obsolete]);
    expect(limits, [300 << 20]);
    expect(configured, [2 << 30]);
    policy.dispose();
  });

  test(
    'unsupported memory and failures keep the limit, with later retry',
    () async {
      var calls = 0;
      final limits = <int>[];
      final errors = <Object>[];
      final policy = ReaderImageCachePolicy(
        readAvailableMemory: () async {
          calls++;
          if (calls == 1) return null;
          if (calls == 2) throw StateError('plugin');
          return 1 << 30;
        },
        setLimit: limits.add,
        onError: (error, stack) => errors.add(error),
      );
      await policy.configure();
      await policy.configure();
      expect(limits, isEmpty);
      expect(errors, hasLength(1));
      await policy.configure();
      expect(limits, [200 << 20]);
      policy.dispose();
      expect(limits, [200 << 20, 100 << 20]);
    },
  );
}
